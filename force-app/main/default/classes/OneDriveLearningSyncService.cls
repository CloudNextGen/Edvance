public class OneDriveLearningSyncService implements Queueable, Database.AllowsCallouts {

    private static final String NAMED_CREDENTIAL = 'OneDrive_Integration';
    private static final Integer CALLOUT_SAFETY_MARGIN = 10;   
    private static final Integer CPU_SAFETY_MARGIN_MS  = 5000; 

    private List<QueueItem> pending;

    public class QueueItem {
        public String driveFolderId { get; set; }
        public String targetFolderDriveId { get; set; } 

        public QueueItem(String driveFolderId, String targetFolderDriveId) {
            this.driveFolderId = driveFolderId;
            this.targetFolderDriveId = targetFolderDriveId;
        }
    }

    public OneDriveLearningSyncService() {
        this(new List<QueueItem>{ new QueueItem('root', 'root') });
    }

    public OneDriveLearningSyncService(List<QueueItem> initialItems) {
        this.pending = initialItems != null ? initialItems : new List<QueueItem>();
    }

    public void execute(QueueableContext context) {
        List<QueueItem> currentLevel = new List<QueueItem>();
        while (!this.pending.isEmpty() && hasRoomToContinue()) {
            currentLevel.add(this.pending.remove(0));
        }

        List<Learning_Folder__c> foldersToUpsert = new List<Learning_Folder__c>();
        // Using a Map for files lets us locate them by their parent folder's Drive ID later
        Map<String, List<Learning_File__c>> filesByParentDriveId = new Map<String, List<Learning_File__c>>();
        List<QueueItem> nextLevelFolders = new List<QueueItem>();

        // --- 1. All Callouts Happen Here ---
        for (QueueItem current : currentLevel) {
            List<Object> children = fetchAllChildren(current.driveFolderId);

            for (Object o : children) {
                Map<String, Object> item = (Map<String, Object>) o;
                String itemId = (String) item.get('id');
                String itemName = (String) item.get('name');

                if (item.containsKey('folder')) {
                    Learning_Folder__c f = new Learning_Folder__c();
                    f.Name = itemName;
                    f.Drive_Folder_Id__c = itemId;
                    
                    if (current.driveFolderId != 'root') {
                        f.Parent_Folder__r = new Learning_Folder__c(Drive_Folder_Id__c = current.driveFolderId);
                    }
                    foldersToUpsert.add(f);
                    nextLevelFolders.add(new QueueItem(itemId, itemId));

                } else if (item.containsKey('file')) {
                    Learning_File__c fileRecord = new Learning_File__c();
                    fileRecord.Name = itemName;
                    fileRecord.Drive_File_Id__c = itemId;

                    if (item.get('webUrl') != null) {
                        fileRecord.Web_View_Link__c = (String) item.get('webUrl');
                    }
                    if (item.get('size') != null) {
                        Long sizeBytes = Long.valueOf(String.valueOf(item.get('size')));
                        fileRecord.Size_Label__c = formatSizeLabel(sizeBytes);
                    }

                    Object fileMeta = item.get('file');
                    if (fileMeta instanceof Map<String, Object>) {
                        Map<String, Object> fileMetaMap = (Map<String, Object>) fileMeta;
                        if (fileMetaMap.get('mimeType') != null) {
                            fileRecord.Mime_Type__c = (String) fileMetaMap.get('mimeType');
                        }
                    }

                    // Group files by their parent drive folder ID string
                    if (!filesByParentDriveId.containsKey(current.driveFolderId)) {
                        filesByParentDriveId.put(current.driveFolderId, new List<Learning_File__c>());
                    }
                    filesByParentDriveId.get(current.driveFolderId).add(fileRecord);
                }
            }
        }

        // --- 2. DML Processing Blocks ---

        // Step A: Upsert Folders and explicitly capture their newly created Salesforce IDs
        Map<String, Id> folderDriveIdToSfIdMap = new Map<String, Id>();
        if (!foldersToUpsert.isEmpty()) {
            Schema.SObjectField externalIdField = Learning_Folder__c.Fields.Drive_Folder_Id__c;
            Database.UpsertResult[] results = Database.upsert(foldersToUpsert, externalIdField, false);

            for (Integer i = 0; i < foldersToUpsert.size(); i++) {
                if (results[i].isSuccess()) {
                    folderDriveIdToSfIdMap.put(foldersToUpsert[i].Drive_Folder_Id__c, results[i].getId());
                }
            }
        }

        // Step B: Query any existing folders that weren't modified in this batch but have files pending
        Set<String> missingFolderDriveIds = new Set<String>(filesByParentDriveId.keySet());
        missingFolderDriveIds.removeAll(folderDriveIdToSfIdMap.keySet());
        missingFolderDriveIds.remove('root');

        if (!missingFolderDriveIds.isEmpty()) {
            for (Learning_Folder__c existingFolder : [SELECT Id, Drive_Folder_Id__c FROM Learning_Folder__c WHERE Drive_Folder_Id__c IN :missingFolderDriveIds]) {
                folderDriveIdToSfIdMap.put(existingFolder.Drive_Folder_Id__c, existingFolder.Id);
            }
        }

        // Step C: Link files using the real, concrete Salesforce folder database IDs
        List<Learning_File__c> finalFilesToUpsert = new List<Learning_File__c>();
        for (String driveId : filesByParentDriveId.keySet()) {
            Id targetSfFolderId = folderDriveIdToSfIdMap.get(driveId);
            
            for (Learning_File__c fileRec : filesByParentDriveId.get(driveId)) {
                // Populate the native lookup field directly with a verified Salesforce ID
                fileRec.Learning_Folder__c = targetSfFolderId; 
                finalFilesToUpsert.add(fileRec);
            }
        }

        // Step D: Commit the files to the database
        if (!finalFilesToUpsert.isEmpty()) {
            Schema.SObjectField fileExternalIdField = Learning_File__c.Fields.Drive_File_Id__c;
            Database.upsert(finalFilesToUpsert, fileExternalIdField, false);
        }

        // Continue processing queue frames
        nextLevelFolders.addAll(this.pending);
        this.pending = nextLevelFolders;

        if (!this.pending.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new OneDriveLearningSyncService(this.pending));
        }
    }

    private Boolean hasRoomToContinue() {
        Integer calloutsLeft = Limits.getLimitCallouts() - Limits.getCallouts();
        Integer cpuLeft = Limits.getLimitCpuTime() - Limits.getCpuTime();
        return calloutsLeft > CALLOUT_SAFETY_MARGIN && cpuLeft > CPU_SAFETY_MARGIN_MS;
    }

    private String formatSizeLabel(Long sizeBytes) {
        if (sizeBytes == null) return null;
        Decimal size = sizeBytes;
        List<String> units = new List<String>{ 'B', 'KB', 'MB', 'GB', 'TB' };
        Integer unitIndex = 0;
        while (size >= 1024 && unitIndex < units.size() - 1) {
            size = size / 1024;
            unitIndex++;
        }
        return size.setScale(1) + ' ' + units[unitIndex];
    }

    private List<Object> fetchAllChildren(String driveFolderId) {
        List<Object> allItems = new List<Object>();
        String endpoint = 'callout:' + NAMED_CREDENTIAL + '/v1.0/me/drive/items/' + driveFolderId + '/children';

        HttpRequest req = new HttpRequest();
        req.setMethod('GET');
        req.setHeader('Content-Type', 'application/json');
        req.setEndpoint(endpoint);

        Http h = new Http();
        HttpResponse res = h.send(req);

        if (res.getStatusCode() == 200) {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            if (body.containsKey('value')) {
                allItems.addAll((List<Object>) body.get('value'));
            }
        }
        return allItems;
    }
}