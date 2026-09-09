public with sharing class LearningAccessAdminController {

    public class FileOption implements Comparable {
        @AuraEnabled public Id fileId;
        @AuraEnabled public String fileName;
        @AuraEnabled public Boolean alreadyGranted;

        public FileOption(Learning_File__c file, Boolean granted) {
            this.fileId = file.Id;
            this.fileName = file.Name;
            this.alreadyGranted = granted;
        }

        public Integer compareTo(Object compareTo) {
            FileOption other = (FileOption) compareTo;
            Integer thisNum = LearningAccessAdminController.extractNumber(this.fileName);
            Integer otherNum = LearningAccessAdminController.extractNumber(other.fileName);
            if (thisNum != otherNum) {
                return thisNum - otherNum;
            }
            return this.fileName.compareTo(other.fileName);
        }
    }

    public class FolderNode implements Comparable {
        @AuraEnabled public Id folderId;
        @AuraEnabled public String folderName;
        @AuraEnabled public List<FolderNode> subFolders;
        @AuraEnabled public List<FileOption> files;

        public FolderNode(Id folderId, String folderName) {
            this.folderId = folderId;
            this.folderName = folderName;
            this.subFolders = new List<FolderNode>();
            this.files = new List<FileOption>();
        }

        public Integer compareTo(Object compareTo) {
            FolderNode other = (FolderNode) compareTo;
            Integer thisNum = LearningAccessAdminController.extractNumber(this.folderName);
            Integer otherNum = LearningAccessAdminController.extractNumber(other.folderName);
            if (thisNum != otherNum) {
                return thisNum - otherNum;
            }
            return this.folderName.compareTo(other.folderName);
        }
    }

    public class TopFolderOption implements Comparable {
        @AuraEnabled public Id folderId;
        @AuraEnabled public String folderName;

        public TopFolderOption(Learning_Folder__c folder) {
            this.folderId = folder.Id;
            this.folderName = folder.Name;
        }

        public Integer compareTo(Object compareTo) {
            TopFolderOption other = (TopFolderOption) compareTo;
            Integer thisNum = LearningAccessAdminController.extractNumber(this.folderName);
            Integer otherNum = LearningAccessAdminController.extractNumber(other.folderName);
            if (thisNum != otherNum) {
                return thisNum - otherNum;
            }
            return this.folderName.compareTo(other.folderName);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<TopFolderOption> getTopLevelFolders() {
        List<TopFolderOption> options = new List<TopFolderOption>();
        for (Learning_Folder__c f : [
            SELECT Id, Name
            FROM Learning_Folder__c
            WHERE Parent_Folder__c = null
        ]) {
            options.add(new TopFolderOption(f));
        }
        options.sort(); // O(N log N)
        return options;
    }

    @AuraEnabled
    public static List<FolderNode> getAssignableFilesTree(Id contactId, String searchTerm, Id topFolderId) {
        // 1. Fetch Granted Access Records
        Set<Id> grantedFileIds = new Set<Id>();
        for (Learning_Access__c la : [
            SELECT Learning_File__c
            FROM Learning_Access__c
            WHERE Contact__c = :contactId
            AND Access_Status__c = 'Granted'
        ]) {
            grantedFileIds.add(la.Learning_File__c);
        }

        // 2. Fetch All Folders
        Map<Id, Learning_Folder__c> allFolders = new Map<Id, Learning_Folder__c>([
            SELECT Id, Name, Parent_Folder__c
            FROM Learning_Folder__c
        ]);

        // Build Parent -> Children Folder Hierarchy Map
        Map<Id, List<Id>> childrenByParent = new Map<Id, List<Id>>();
        for (Learning_Folder__c f : allFolders.values()) {
            if (f.Parent_Folder__c != null) {
                if (!childrenByParent.containsKey(f.Parent_Folder__c)) {
                    childrenByParent.put(f.Parent_Folder__c, new List<Id>());
                }
                childrenByParent.get(f.Parent_Folder__c).add(f.Id);
            }
        }

        // Restrict by Selected Category Top Folder if chosen
        Set<Id> categoryAllowedFolders = null;
        if (topFolderId != null) {
            categoryAllowedFolders = new Set<Id>();
            collectDescendantFolderIds(topFolderId, childrenByParent, categoryAllowedFolders);
        }

        // 3. Process Files & Apply Precise Search Logic
        String term = String.isBlank(searchTerm) ? '' : searchTerm.trim().toLowerCase();

        Map<Id, List<FileOption>> filesByFolderMap = new Map<Id, List<FileOption>>();
        Set<Id> activeFolderIds = new Set<Id>();

        for (Learning_File__c file : [
            SELECT Id, Name, Learning_Folder__c
            FROM Learning_File__c
            WHERE Learning_Folder__c != null
        ]) {
            Id folderId = file.Learning_Folder__c;

            // Skip if outside category dropdown scope
            if (categoryAllowedFolders != null && !categoryAllowedFolders.contains(folderId)) {
                continue;
            }

            Boolean isMatch = false;

            if (String.isBlank(term)) {
                isMatch = true;
            } else {
                // Strict Matching Criteria: File Name OR Direct Parent Folder Name matches search
                Boolean fileNameMatches = file.Name != null && file.Name.toLowerCase().contains(term);
                
                Learning_Folder__c directFolder = allFolders.get(folderId);
                Boolean directFolderMatches = directFolder != null && directFolder.Name != null && directFolder.Name.toLowerCase().contains(term);

                if (fileNameMatches || directFolderMatches) {
                    isMatch = true;
                }
            }

            if (!isMatch) {
                continue;
            }

            // Group matched files
            if (!filesByFolderMap.containsKey(folderId)) {
                filesByFolderMap.put(folderId, new List<FileOption>());
            }
            Boolean isGranted = grantedFileIds.contains(file.Id);
            filesByFolderMap.get(folderId).add(new FileOption(file, isGranted));

            // Mark ancestor folder path to preserve tree structure
            Id curr = folderId;
            while (curr != null && allFolders.containsKey(curr)) {
                activeFolderIds.add(curr);
                curr = allFolders.get(curr).Parent_Folder__c;
            }
        }

        // 4. Determine Tree Roots
        List<Id> rootIds = new List<Id>();
        if (topFolderId != null) {
            if (activeFolderIds.contains(topFolderId)) {
                rootIds.add(topFolderId);
            }
        } else {
            for (Id fid : activeFolderIds) {
                if (allFolders.get(fid).Parent_Folder__c == null) {
                    rootIds.add(fid);
                }
            }
        }

        // 5. Build Recursive Tree Structure
        List<FolderNode> resultTree = new List<FolderNode>();
        for (Id rootId : rootIds) {
            FolderNode rootNode = buildTreeBranch(rootId, allFolders, childrenByParent, filesByFolderMap, activeFolderIds);
            if (rootNode != null) {
                resultTree.add(rootNode);
            }
        }

        resultTree.sort(); // Sort root level folders naturally
        return resultTree;
    }

    private static FolderNode buildTreeBranch(
        Id currentFolderId,
        Map<Id, Learning_Folder__c> allFolders,
        Map<Id, List<Id>> childrenByParent,
        Map<Id, List<FileOption>> filesByFolderMap,
        Set<Id> activeFolderIds
    ) {
        if (!activeFolderIds.contains(currentFolderId)) {
            return null;
        }

        FolderNode node = new FolderNode(currentFolderId, allFolders.get(currentFolderId).Name);

        // Process Subfolders
        if (childrenByParent.containsKey(currentFolderId)) {
            for (Id childId : childrenByParent.get(currentFolderId)) {
                FolderNode childNode = buildTreeBranch(childId, allFolders, childrenByParent, filesByFolderMap, activeFolderIds);
                if (childNode != null) {
                    node.subFolders.add(childNode);
                }
            }
            node.subFolders.sort(); // Fast native sort
        }

        // Process Files
        if (filesByFolderMap.containsKey(currentFolderId)) {
            node.files = filesByFolderMap.get(currentFolderId);
            node.files.sort(); // Fast native sort
        }

        return node;
    }

    private static void collectDescendantFolderIds(Id folderId, Map<Id, List<Id>> childrenMap, Set<Id> resultSet) {
        resultSet.add(folderId);
        if (childrenMap.containsKey(folderId)) {
            for (Id childId : childrenMap.get(folderId)) {
                collectDescendantFolderIds(childId, childrenMap, resultSet);
            }
        }
    }

    // Extraction helper for natural sorting (e.g. "Path-4" -> 4, "10-Access" -> 10)
    public static Integer extractNumber(String str) {
        if (String.isBlank(str)) return 9999;
        
        String digits = '';
        for (Integer i = 0; i < str.length(); i++) {
            String ch = str.substring(i, i + 1);
            if (ch.isNumeric()) {
                digits += ch;
            } else if (digits.length() > 0) {
                break;
            }
        }
        
        return String.isNotBlank(digits) ? Integer.valueOf(digits) : 9999;
    }

    @AuraEnabled
    public static void assignFilesToContact(Id contactId, List<Id> fileIds) {
        if (fileIds == null || fileIds.isEmpty()) {
            throw new AuraHandledException('No files selected.');
        }

        Contact con = [SELECT Id, Name FROM Contact WHERE Id = :contactId LIMIT 1];

        Map<Id, Learning_File__c> filesMap = new Map<Id, Learning_File__c>([
            SELECT Id, Name FROM Learning_File__c WHERE Id IN :fileIds
        ]);

        Map<Id, Learning_Access__c> existingAccessMap = new Map<Id, Learning_Access__c>();
        for (Learning_Access__c la : [
            SELECT Id, Learning_File__c, Access_Status__c, Name
            FROM Learning_Access__c
            WHERE Contact__c = :contactId AND Learning_File__c IN :fileIds
        ]) {
            existingAccessMap.put(la.Learning_File__c, la);
        }

        List<Learning_Access__c> toInsert = new List<Learning_Access__c>();
        List<Learning_Access__c> toUpdate = new List<Learning_Access__c>();
        Datetime now = Datetime.now();

        for (Id fileId : fileIds) {
            Learning_File__c file = filesMap.get(fileId);
            if (file == null) continue;

            String recordName = buildAccessName(file.Name, con.Name);
            Learning_Access__c existing = existingAccessMap.get(fileId);

            if (existing == null) {
                Learning_Access__c la = new Learning_Access__c(
                    Name = recordName,
                    Contact__c = contactId,
                    Learning_File__c = fileId,
                    Access_Status__c = 'Granted',
                    Completion_Status__c = 'Not Started',
                    Granted_Date__c = now
                );
                toInsert.add(la);
            } else if (existing.Access_Status__c != 'Granted') {
                existing.Access_Status__c = 'Granted';
                existing.Granted_Date__c = now;
                existing.Revoked_Date__c = null;
                existing.Name = recordName;
                toUpdate.add(existing);
            }
        }

        if (!toInsert.isEmpty()) insert toInsert;
        if (!toUpdate.isEmpty()) update toUpdate;
    }

    private static String buildAccessName(String fileName, String contactName) {
        String suffix = ' - ' + contactName;
        Integer maxFileNameLength = 80 - suffix.length();

        if (maxFileNameLength < 1) {
            return (fileName + suffix).left(80);
        }

        String truncatedFileName = fileName.length() > maxFileNameLength
            ? fileName.left(maxFileNameLength)
            : fileName;

        return truncatedFileName + suffix;
    }
}