public without sharing class LearningContentController {
    private static final String QUEUE_DEV_NAME = 'Learning_File_Review_Queue';
    private static final String NOTIFICATION_TYPE_DEV_NAME = 'Task_Assigned_to_Queue';
    private static final String MENTOR_PERMISSION = 'Portal_Mentor_Access';
    private static final Set<String> SYSTEM_ADMIN_PERMISSIONS = new Set<String>{
        'Assign_Files',
        'View_Assignments',
        'View_Attendance',
        'Portal_HR_Access',
        'Portal_Mentor_Access',
        'Portal_Team_Member_Access'
    };
    private static final String NEXT_ACCESS_LOCKED_MESSAGE = '⚠️ Next file and folder are locked. Please contact your Admin/Mentor for access.';
    @TestVisible private static Boolean autoAssignNextFileOverride;
    @TestVisible private static Boolean autoAssignNextFolderOverride;
    private static Id learningRequestQueueId;
    private static Map<Id, Boolean> mentorAccessByUserId = new Map<Id, Boolean>();
    @TestVisible private static Boolean autoCreateAssignmentEligibilityOverride;

    public class FolderNode {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal sortOrder;
        @AuraEnabled public Integer totalFilesCount;
        @AuraEnabled public Integer visibleFilesCount;
        @AuraEnabled public List<FolderNode> subFolders;
        @AuraEnabled public List<FileNode> files;
    }

    public class FileNode {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String mimeType;
        @AuraEnabled public String webViewLink;
        @AuraEnabled public String sizeLabel;
        @AuraEnabled public String completionStatus;
        @AuraEnabled public String learningAccessId;
        @AuraEnabled public Integer estimatedTimeMinutes;
        @AuraEnabled public DateTime dateTimeOpened;
        @AuraEnabled public Decimal sortOrder;
        @AuraEnabled public Boolean accessRevoked;
    }

    public class RecentFileWrapper {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String mimeType;
        @AuraEnabled public String url;
        @AuraEnabled public DateTime lastAccessed;
    }

    // ═══════════════════════════════════════════════════════════════
    // Natural sort helpers — Sort_Order__c is the primary ordering key,
    // but when it's missing/tied we fall back to a numeric-aware name
    // compare instead of plain alphabetical, so "10" doesn't sort before
    // "2". This mirrors the client-side naturalCompare() in the LWC.
    // ═══════════════════════════════════════════════════════════════

    private static String naturalSortKey(String s) {
        if (String.isBlank(s)) {
            return '';
        }
        String result = '';
        Integer i = 0;
        Integer len = s.length();
        while (i < len) {
            String ch = s.substring(i, i + 1);
            if (ch.isNumeric()) {
                Integer j = i;
                String numStr = '';
                while (j < len && s.substring(j, j + 1).isNumeric()) {
                    numStr += s.substring(j, j + 1);
                    j++;
                }
                // Zero-pad so numeric chunks compare correctly as strings
                result += numStr.leftPad(15, '0');
                i = j;
            } else {
                result += ch.toLowerCase();
                i++;
            }
        }
        return result;
    
    }

    private class FileNaturalComparator implements Comparator<Learning_File__c> {
        public Integer compare(Learning_File__c a, Learning_File__c b) {
            Decimal aOrder = a.Sort_Order__c;
            Decimal bOrder = b.Sort_Order__c;
            if (aOrder != null && bOrder != null && aOrder != bOrder) {
                return aOrder > bOrder ? 1 : -1;
            }
            if (aOrder != null && bOrder == null) return -1;
            if (aOrder == null && bOrder != null) return 1;

            String aKey = naturalSortKey(a.Name);
            String bKey = naturalSortKey(b.Name);
            if (aKey < bKey) return -1;
            if (aKey > bKey) return 1;
            return 0;
        }
    }

    private class FolderNaturalComparator implements Comparator<Learning_Folder__c> {
        public Integer compare(Learning_Folder__c a, Learning_Folder__c b) {
            Decimal aOrder = a.Sort_Order__c;
            Decimal bOrder = b.Sort_Order__c;
            if (aOrder != null && bOrder != null && aOrder != bOrder) {
                return aOrder > bOrder ? 1 : -1;
            }
            if (aOrder != null && bOrder == null) return -1;
            if (aOrder == null && bOrder != null) return 1;

            String aKey = naturalSortKey(a.Name);
            String bKey = naturalSortKey(b.Name);
            if (aKey < bKey) return -1;
            if (aKey > bKey) return 1;
            return 0;
        }
    }

    private static Boolean hasMentorOrAdminAccess(User assignedMentor) {
        if (assignedMentor == null || !assignedMentor.IsActive) {
            return false;
        }
        if (mentorAccessByUserId.containsKey(assignedMentor.Id)) {
            return mentorAccessByUserId.get(assignedMentor.Id);
        }

        Boolean hasAccess = calculateMentorOrAdminAccess(assignedMentor);
        mentorAccessByUserId.put(assignedMentor.Id, hasAccess);
        return hasAccess;
    }

    private static Boolean calculateMentorOrAdminAccess(User assignedMentor) {
        Set<String> relevantPermissions = new Set<String>(SYSTEM_ADMIN_PERMISSIONS);
        relevantPermissions.add(MENTOR_PERMISSION);
        Map<Id, String> permissionNamesById = new Map<Id, String>();
        for (CustomPermission permission : [
            SELECT Id, DeveloperName
            FROM CustomPermission
            WHERE DeveloperName IN :relevantPermissions
            WITH SYSTEM_MODE
        ]) {
            permissionNamesById.put(permission.Id, permission.DeveloperName);
        }
        if (permissionNamesById.isEmpty()) {
            return false;
        }

        Set<Id> permissionSetIds = new Set<Id>();
        for (PermissionSet profilePermissionSet : [
            SELECT Id
            FROM PermissionSet
            WHERE ProfileId = :assignedMentor.ProfileId
            WITH SYSTEM_MODE
        ]) {
            permissionSetIds.add(profilePermissionSet.Id);
        }

        Set<Id> permissionSetGroupIds = new Set<Id>();
        for (PermissionSetAssignment assignment : [
            SELECT PermissionSetId, PermissionSetGroupId
            FROM PermissionSetAssignment
            WHERE AssigneeId = :assignedMentor.Id
            WITH SYSTEM_MODE
        ]) {
            if (assignment.PermissionSetId != null) {
                permissionSetIds.add(assignment.PermissionSetId);
            }
            if (assignment.PermissionSetGroupId != null) {
                permissionSetGroupIds.add(assignment.PermissionSetGroupId);
            }
        }

        if (!permissionSetGroupIds.isEmpty()) {
            for (PermissionSetGroupComponent component : [
                SELECT PermissionSetId
                FROM PermissionSetGroupComponent
                WHERE PermissionSetGroupId IN :permissionSetGroupIds
                WITH SYSTEM_MODE
            ]) {
                permissionSetIds.add(component.PermissionSetId);
            }
        }

        if (permissionSetIds.isEmpty()) {
            return false;
        }

        Set<String> grantedPermissions = new Set<String>();
        for (SetupEntityAccess access : [
            SELECT ParentId, SetupEntityId
            FROM SetupEntityAccess
            WHERE ParentId IN :permissionSetIds
              AND SetupEntityId IN :permissionNamesById.keySet()
            WITH SYSTEM_MODE
        ]) {
            grantedPermissions.add(permissionNamesById.get(access.SetupEntityId));
        }

        if (grantedPermissions.contains(MENTOR_PERMISSION)) {
            return true;
        }
        for (String adminPermission : SYSTEM_ADMIN_PERMISSIONS) {
            if (!grantedPermissions.contains(adminPermission)) {
                return false;
            }
        }
        return true;
    }

    private static String buildLearningAccessName(String fileName, String userName) {
        String safeFileName = String.isBlank(fileName) ? 'Learning File' : fileName;
        String safeUserName = String.isBlank(userName) ? 'Unknown User' : userName;
        return safeFileName + ' - ' + safeUserName;
    }

    private static void applyLearningAccessName(Learning_Access__c accessRecord, Learning_File__c fileRecord) {
        if (accessRecord == null || fileRecord == null) {
            return;
        }

        String userName = UserInfo.getName();
        if (String.isBlank(userName)) {
            userName = UserInfo.getUserName();
        }

        accessRecord.Name = buildLearningAccessName(fileRecord.Name, userName);
    }

    @AuraEnabled
    public static List<FolderNode> getLearningContentTree() {
        LearningAccessAdminController.assertTeamMemberAccessAllowed();
        Boolean isAdmin = isCurrentUserAdmin();
        Id contactId = getCurrentContactId();

        Map<Id, Learning_Folder__c> allFolders = new Map<Id, Learning_Folder__c>(
            [SELECT Id, Name, Parent_Folder__c, Sort_Order__c
             FROM Learning_Folder__c
             ORDER BY Sort_Order__c NULLS LAST, Name]
        );

        List<Learning_File__c> allFiles = [
            SELECT Id, Name, Mime_Type__c, Web_View_Link__c, Size_Label__c,
                   Learning_Folder__c, Sort_Order__c, Estimated_Time__c
            FROM Learning_File__c
            WHERE Learning_Folder__c != null
            ORDER BY Sort_Order__c NULLS LAST, Name
        ];

        // ─── Determine which files this user can actually see ──────────────
        Map<Id, Learning_Access__c> accessByFileId = new Map<Id, Learning_Access__c>();
        Map<Id, Learning_Access__c> blockedAccessByFileId = new Map<Id, Learning_Access__c>();
        Set<Id> visibleFileIds = new Set<Id>();

        if (isAdmin) {
            for (Learning_File__c f : allFiles) {
                visibleFileIds.add(f.Id);
            }
        } else if (contactId != null) {
            for (Learning_Access__c acc : [
                SELECT Id, Learning_File__c, Completion_Status__c, Date_Time_Opened__c, Access_Status__c
                FROM Learning_Access__c
                WHERE Contact__c = :contactId
            ]) {
                if (acc.Access_Status__c == 'Granted') {
                    visibleFileIds.add(acc.Learning_File__c);
                    accessByFileId.put(acc.Learning_File__c, acc);
                } else if (acc.Learning_File__c != null && acc.Access_Status__c == 'Revoked') {
                    blockedAccessByFileId.put(acc.Learning_File__c, acc);
                }
            }
        }

        // ─── Group visible files by folder ──────────────────────────────────
        Map<Id, List<FileNode>> filesByFolder = new Map<Id, List<FileNode>>();
        Map<Id, Integer> totalFileCountByFolder = new Map<Id, Integer>();
        Map<Id, Integer> visibleFileCountByFolder = new Map<Id, Integer>();
        Set<Id> foldersWithVisibleContent = new Set<Id>();

        for (Learning_File__c f : allFiles) {
            if (f.Learning_Folder__c != null) {
                Integer currentCount = totalFileCountByFolder.containsKey(f.Learning_Folder__c)
                    ? totalFileCountByFolder.get(f.Learning_Folder__c)
                    : 0;
                totalFileCountByFolder.put(f.Learning_Folder__c, currentCount + 1);
            }

            Boolean isVisible = isAdmin || visibleFileIds.contains(f.Id);
            Boolean isBlocked = !isVisible && blockedAccessByFileId.containsKey(f.Id);
            if (!isVisible && !isBlocked) {
                continue;
            }

            FileNode fn = new FileNode();
            fn.id = f.Id;
            fn.name = f.Name;
            fn.mimeType = f.Mime_Type__c;
            fn.webViewLink = f.Web_View_Link__c;
            fn.sizeLabel = f.Size_Label__c;
            fn.sortOrder = f.Sort_Order__c;
            fn.accessRevoked = isBlocked;
            // Default estimated time to 1 minute if not set
            fn.estimatedTimeMinutes = f.Estimated_Time__c != null ? (Integer) f.Estimated_Time__c : 1;

            if (accessByFileId.containsKey(f.Id)) {
                Learning_Access__c access = accessByFileId.get(f.Id);
                fn.learningAccessId = access.Id;
                fn.completionStatus = access.Completion_Status__c != null ? access.Completion_Status__c : 'Not Started';
                fn.dateTimeOpened = access.Date_Time_Opened__c;
            } else {
                fn.completionStatus = 'Not Started';
                fn.dateTimeOpened = null;
            }

            if (!filesByFolder.containsKey(f.Learning_Folder__c)) {
                filesByFolder.put(f.Learning_Folder__c, new List<FileNode>());
            }
            filesByFolder.get(f.Learning_Folder__c).add(fn);
            foldersWithVisibleContent.add(f.Learning_Folder__c);

            if (isVisible) {
                Integer currentVisibleCount = visibleFileCountByFolder.containsKey(f.Learning_Folder__c)
                    ? visibleFileCountByFolder.get(f.Learning_Folder__c)
                    : 0;
                visibleFileCountByFolder.put(f.Learning_Folder__c, currentVisibleCount + 1);
            }
        }

        // ─── Walk up ancestors so parent folders are reachable ──────────────
        Set<Id> visibleFolderIds = new Set<Id>();
        for (Id folderId : foldersWithVisibleContent) {
            Id current = folderId;
            while (current != null && !visibleFolderIds.contains(current)) {
                visibleFolderIds.add(current);
                Learning_Folder__c folder = allFolders.get(current);
                current = (folder != null) ? folder.Parent_Folder__c : null;
            }
        }

        if (isAdmin) {
            visibleFolderIds = allFolders.keySet();
        }

        // ─── Build folder node tree ──────────────────────────────────────────
        Map<Id, FolderNode> nodeMap = new Map<Id, FolderNode>();
        for (Id folderId : visibleFolderIds) {
            Learning_Folder__c folder = allFolders.get(folderId);
            if (folder == null) {
                continue;
            }

            FolderNode node = new FolderNode();
            node.id = folder.Id;
            node.name = folder.Name;
            node.sortOrder = folder.Sort_Order__c;
            node.totalFilesCount = totalFileCountByFolder.containsKey(folder.Id) ? totalFileCountByFolder.get(folder.Id) : 0;
            node.visibleFilesCount = visibleFileCountByFolder.containsKey(folder.Id) ? visibleFileCountByFolder.get(folder.Id) : 0;
            node.subFolders = new List<FolderNode>();
            node.files = filesByFolder.containsKey(folder.Id) ? filesByFolder.get(folder.Id) : new List<FileNode>();

            nodeMap.put(folder.Id, node);
        }

        List<FolderNode> rootNodes = new List<FolderNode>();
        for (Id folderId : visibleFolderIds) {
            Learning_Folder__c folder = allFolders.get(folderId);
            FolderNode node = nodeMap.get(folderId);
            if (folder == null || node == null) {
                continue;
            }

            if (folder.Parent_Folder__c != null && nodeMap.containsKey(folder.Parent_Folder__c)) {
                nodeMap.get(folder.Parent_Folder__c).subFolders.add(node);
            } else {
                rootNodes.add(node);
            }
        }

        return rootNodes;
    }

    private static Boolean isCurrentUserAdmin() {
        if (UserInfo.getUserType() == 'Guest') {
            return false;
        }

        try {
            Id currentUserId = UserInfo.getUserId();
            String query = 'SELECT Id FROM User WHERE Id = :currentUserId AND Profile.Name = \'System Administrator\' LIMIT 1';
            List<User> standardUser = Database.query(query);
            return !standardUser.isEmpty();
        } catch (Exception e) {
            ErrorLogger.log(e);
            return false;
        }
    }

    private static Id getCurrentContactId() {
        if (UserInfo.getUserType() == 'Guest') {
            return null;
        }

        try {
            List<User> users = [SELECT ContactId FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
            return !users.isEmpty() ? users[0].ContactId : null;
        } catch (Exception e) {
            ErrorLogger.log(e);
            return null;
        }
    }

    @AuraEnabled
    public static Boolean hasRequestedNextContentAccess(Id currentFolderId) {
        Map<String, Object> status = getNextContentAccessRequestStatus(currentFolderId);
        return (Boolean) status.get('alreadyRequested');
    }

    @AuraEnabled
    public static Map<String, Object> getNextContentAccessRequestStatus(Id currentFolderId) {
        Map<String, Object> status = new Map<String, Object>{
            'available' => false,
            'alreadyRequested' => false,
            'requestStatus' => null,
            'canNotifyAgain' => false
        };
        if (currentFolderId == null) {
            return status;
        }
        if (isAutoCreateAssignmentEligibilityEnabled()) {
            return status;
        }

        Id contactId = getCurrentContactId();
        if (contactId == null) {
            return status;
        }

        Learning_File__c nextLockedFile = getNextLockedFile(contactId, currentFolderId);
        if (nextLockedFile == null) {
            return status;
        }

        String subject = buildLearningAccessRequestSubject(nextLockedFile);
        List<Case> existingRequests = [
            SELECT Id, Status
            FROM Case
            WHERE ContactId = :contactId
              AND Type = 'Other'
              AND Subject = :subject
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        Boolean alreadyRequested = !existingRequests.isEmpty();
        String requestStatus = alreadyRequested ? existingRequests[0].Status : null;
        status.put('available', true);
        status.put('alreadyRequested', alreadyRequested);
        status.put('requestStatus', requestStatus);
        status.put('canNotifyAgain', requestStatus == 'New');
        return status;
    }

    @AuraEnabled
    public static Map<String, Object> requestNextContentAccess(Id currentFolderId) {
        if (currentFolderId == null) {
            throw new AuraHandledException('The current learning folder is required.');
        }
        if (isAutoCreateAssignmentEligibilityEnabled()) {
            throw new AuraHandledException(
                'Mentor access requests for learning files are unavailable while automatic assignment eligibility is enabled.'
            );
        }

        Id contactId = getCurrentContactId();
        if (contactId == null) {
            throw new AuraHandledException('Your community user is not linked to a Contact.');
        }

        List<Contact> contacts = [
            SELECT Id, Name, Mentor__c
            FROM Contact
            WHERE Id = :contactId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (contacts.isEmpty()) {
            throw new AuraHandledException('Your learner Contact could not be found.');
        }

        Contact learner = contacts[0];
        Id mentorId;
        if (learner.Mentor__c != null) {
            List<User> assignedMentors = [
                SELECT Id, IsActive, ProfileId
                FROM User
                WHERE Id = :learner.Mentor__c AND IsActive = true
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (!assignedMentors.isEmpty() && hasMentorOrAdminAccess(assignedMentors[0])) {
                mentorId = assignedMentors[0].Id;
            }
        }

        if (mentorId == null) {
            throw new AuraHandledException(
                'No active mentor with mentor or System Administrator access is assigned to your Contact. ' +
                'Please contact your administrator.'
            );
        }
        Id reviewQueueId = getLearningRequestQueueId();

        Learning_File__c nextLockedFile = getNextLockedFile(contactId, currentFolderId);
        if (nextLockedFile == null) {
            throw new AuraHandledException('There are no additional locked files in this folder to request.');
        }

        String subject = buildLearningAccessRequestSubject(nextLockedFile);
        List<Case> existingRequests = [
            SELECT Id, OwnerId, Status
            FROM Case
            WHERE ContactId = :contactId
              AND Type = 'Other'
              AND Subject = :subject
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!existingRequests.isEmpty()) {
            String message = 'You have already submitted an access request for "' + nextLockedFile.Name + '".';
            if (existingRequests[0].Status == 'New') {
                message = notifyMentorOfLearningAccessRequest(
                    mentorId,
                    existingRequests[0].Id,
                    learner.Name,
                    nextLockedFile.Name,
                    true
                );
            }
            return new Map<String, Object>{
                'success' => true,
                'caseId' => existingRequests[0].Id,
                'alreadyRequested' => true,
                'requestStatus' => existingRequests[0].Status,
                'canNotifyAgain' => existingRequests[0].Status == 'New',
                'message' => message
            };
        }

        Case accessRequest = new Case(
            ContactId = contactId,
            OwnerId = reviewQueueId,
            Subject = subject,
            Type = 'Other',
            Status = 'New',
            Description = 'The learner is requesting access to the locked file "' +
                nextLockedFile.Name + '". Learner: ' + learner.Name + '.'
        );
        Database.SaveResult saveResult = Database.insert(
            accessRequest,
            false,
            AccessLevel.SYSTEM_MODE
        );
        if (!saveResult.isSuccess()) {
            throw new AuraHandledException(
                'Unable to submit the access request: ' +
                saveResult.getErrors()[0].getMessage()
            );
        }

        String message = notifyMentorOfLearningAccessRequest(
            mentorId,
            saveResult.getId(),
            learner.Name,
            nextLockedFile.Name,
            false
        );

        return new Map<String, Object>{
            'success' => true,
            'caseId' => saveResult.getId(),
            'alreadyRequested' => false,
            'requestStatus' => 'New',
            'canNotifyAgain' => true,
            'message' => message
        };
    }

    private static Boolean isAutoCreateAssignmentEligibilityEnabled() {
        if (autoCreateAssignmentEligibilityOverride != null) {
            return autoCreateAssignmentEligibilityOverride;
        }
        List<Assessment_Portal_Config__mdt> settings = [
            SELECT Auto_Create_Assignment_Eligibility__c
            FROM Assessment_Portal_Config__mdt
            WHERE DeveloperName = 'Default'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (settings.isEmpty()) {
            throw new AuraHandledException('The default assessment portal configuration is missing.');
        }
        return settings[0].Auto_Create_Assignment_Eligibility__c == true;
    }

    private static Id getLearningRequestQueueId() {
        if (learningRequestQueueId != null) {
            return learningRequestQueueId;
        }

        List<Group> queues = [
            SELECT Id
            FROM Group
            WHERE Type = 'Queue'
              AND DeveloperName = :QUEUE_DEV_NAME
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (queues.isEmpty()) {
            throw new AuraHandledException(
                'The Learning File Review Queue is not configured. Please contact your administrator.'
            );
        }

        List<QueueSobject> caseQueueAssignments = [
            SELECT Id
            FROM QueueSobject
            WHERE QueueId = :queues[0].Id
              AND SobjectType = 'Case'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (caseQueueAssignments.isEmpty()) {
            throw new AuraHandledException(
                'The Learning File Review Queue is not configured to own Cases. ' +
                'Please contact your administrator.'
            );
        }
        learningRequestQueueId = queues[0].Id;
        return learningRequestQueueId;
    }

    private static String notifyMentorOfLearningAccessRequest(
        Id mentorId,
        Id caseId,
        String learnerName,
        String fileName,
        Boolean isReminder
    ) {
        List<String> sentChannels = new List<String>();
        List<String> notificationErrors = new List<String>();
        try {
            List<CustomNotificationType> notificationTypes = [
                SELECT Id
                FROM CustomNotificationType
                WHERE DeveloperName = :NOTIFICATION_TYPE_DEV_NAME
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (!notificationTypes.isEmpty()) {
                Messaging.CustomNotification notification = new Messaging.CustomNotification();
                notification.setTitle(isReminder ? 'Learning Access Reminder' : 'Learning Access Requested');
                notification.setBody(learnerName + ' requested access to "' + fileName + '".');
                notification.setNotificationTypeId(notificationTypes[0].Id);
                notification.setTargetId(caseId);
                notification.send(new Set<String>{ String.valueOf(mentorId) });
                sentChannels.add('Salesforce notification');
            } else {
                notificationErrors.add('Salesforce notification type is not configured.');
            }
        } catch (Exception e) {
            ErrorLogger.log(e);
            notificationErrors.add('Salesforce notification could not be sent: ' + e.getMessage());
        }

        try {
            List<User> mentors = [
                SELECT Email
                FROM User
                WHERE Id = :mentorId AND IsActive = true
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (mentors.isEmpty() || String.isBlank(mentors[0].Email)) {
                notificationErrors.add('The mentor does not have an active user email address.');
            } else {
                Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
                email.setToAddresses(new List<String>{ mentors[0].Email });
                email.setSubject((isReminder ? 'Reminder: ' : '') + 'Learning access requested by ' + learnerName);
                email.setPlainTextBody(
                    learnerName + ' is requesting access to "' + fileName + '".\n\n' +
                    'Review the request in Salesforce: ' +
                    URL.getOrgDomainUrl().toExternalForm() + '/' + caseId
                );
                email.setSaveAsActivity(false);
                Messaging.SendEmailResult[] emailResults = Messaging.sendEmail(
                    new List<Messaging.SingleEmailMessage>{ email },
                    false
                );
                if (!emailResults.isEmpty() && emailResults[0].isSuccess()) {
                    sentChannels.add('email');
                } else {
                    List<String> emailErrors = new List<String>();
                    if (!emailResults.isEmpty()) {
                        for (Messaging.SendEmailError emailError : emailResults[0].getErrors()) {
                            emailErrors.add(emailError.getMessage());
                        }
                    }
                    notificationErrors.add(
                        'Mentor email could not be sent: ' +
                        (emailErrors.isEmpty() ? 'Salesforce returned no delivery details.' : String.join(emailErrors, '; '))
                    );
                }
            }
        } catch (Exception e) {
            ErrorLogger.log(e);
            notificationErrors.add('Mentor email could not be sent: ' + e.getMessage());
        }

        String message = isReminder
            ? 'The existing access request for "' + fileName + '" remains open.'
            : 'Your access request for "' + fileName + '" was recorded.';
        if (!sentChannels.isEmpty()) {
            message += ' Mentor notified by ' + String.join(sentChannels, ' and ') + '.';
        }
        if (!notificationErrors.isEmpty()) {
            String errors = String.join(notificationErrors, ' ');
            ErrorLogger.log(errors);
            message += ' ' + errors;
        }
        return message;
    }

    private static Learning_File__c getNextLockedFile(Id contactId, Id folderId) {
        List<Learning_Folder__c> folders = [
            SELECT Id, Name, Parent_Folder__c, Sort_Order__c
            FROM Learning_Folder__c
            WITH SYSTEM_MODE
        ];
        folders.sort(new FolderNaturalComparator());

        Map<Id, List<Learning_Folder__c>> childrenByParent = new Map<Id, List<Learning_Folder__c>>();
        List<Learning_Folder__c> rootFolders = new List<Learning_Folder__c>();
        for (Learning_Folder__c folder : folders) {
            if (folder.Parent_Folder__c == null) {
                rootFolders.add(folder);
            } else {
                if (!childrenByParent.containsKey(folder.Parent_Folder__c)) {
                    childrenByParent.put(folder.Parent_Folder__c, new List<Learning_Folder__c>());
                }
                childrenByParent.get(folder.Parent_Folder__c).add(folder);
            }
        }

        List<Id> orderedFolderIds = new List<Id>();
        appendOrderedFolderIds(rootFolders, childrenByParent, orderedFolderIds);
        Integer currentFolderIndex = orderedFolderIds.indexOf(folderId);
        if (currentFolderIndex < 0) {
            return null;
        }

        Set<Id> candidateFolderIds = new Set<Id>();
        for (Integer i = currentFolderIndex; i < orderedFolderIds.size(); i++) {
            candidateFolderIds.add(orderedFolderIds[i]);
        }

        List<Learning_File__c> allFiles = [
            SELECT Id, Name, Learning_Folder__c, Sort_Order__c
            FROM Learning_File__c
            WHERE Learning_Folder__c IN :candidateFolderIds
            WITH SYSTEM_MODE
        ];
        if (allFiles.isEmpty()) {
            return null;
        }
        allFiles.sort(new FileNaturalComparator());

        Set<Id> allFileIds = new Map<Id, Learning_File__c>(allFiles).keySet();
        Set<Id> grantedFileIds = new Set<Id>();
        for (Learning_Access__c accessRecord : [
            SELECT Learning_File__c
            FROM Learning_Access__c
            WHERE Contact__c = :contactId
              AND Access_Status__c = 'Granted'
              AND Learning_File__c IN :allFileIds
            WITH SYSTEM_MODE
        ]) {
            grantedFileIds.add(accessRecord.Learning_File__c);
        }

        Map<Id, List<Learning_File__c>> filesByFolder = new Map<Id, List<Learning_File__c>>();
        for (Learning_File__c file : allFiles) {
            if (!filesByFolder.containsKey(file.Learning_Folder__c)) {
                filesByFolder.put(file.Learning_Folder__c, new List<Learning_File__c>());
            }
            filesByFolder.get(file.Learning_Folder__c).add(file);
        }

        for (Integer i = currentFolderIndex; i < orderedFolderIds.size(); i++) {
            List<Learning_File__c> folderFiles = filesByFolder.get(orderedFolderIds[i]);
            if (folderFiles == null) {
                continue;
            }
            for (Learning_File__c file : folderFiles) {
                if (!grantedFileIds.contains(file.Id)) {
                    return file;
                }
            }
        }
        return null;
    }

    private static void appendOrderedFolderIds(
        List<Learning_Folder__c> folders,
        Map<Id, List<Learning_Folder__c>> childrenByParent,
        List<Id> orderedFolderIds
    ) {
        for (Learning_Folder__c folder : folders) {
            orderedFolderIds.add(folder.Id);
            List<Learning_Folder__c> childFolders = childrenByParent.get(folder.Id);
            if (childFolders != null) {
                appendOrderedFolderIds(childFolders, childrenByParent, orderedFolderIds);
            }
        }
    }

    private static String buildLearningAccessRequestSubject(Learning_File__c file) {
        return 'Learning access request: ' + file.Name + ' (' + file.Id + ')';
    }

    @AuraEnabled
    public static Map<String, Object> markFileComplete(String fileId) {
        Map<String, Object> result = new Map<String, Object>();

        try {
            LearningAccessAdminController.assertTeamMemberAccessAllowed();
            Id contactId = getCurrentContactId();
            if (contactId == null) {
                throw new AuraHandledException('Unable to determine current user contact');
            }
            if (String.isBlank(fileId)) {
                throw new AuraHandledException('File Id is required');
            }

            List<Learning_File__c> currentFileList = [
                SELECT Id, Name, Learning_Folder__c, Sort_Order__c, Owner.Name
                FROM Learning_File__c
                WHERE Id = :fileId
                LIMIT 1
            ];
            if (currentFileList.isEmpty()) {
                throw new AuraHandledException('Learning File record not found');
            }
            Learning_File__c currentFile = currentFileList[0];

            // Resolve (or create) the Learning_Access__c for this contact/file
            List<Learning_Access__c> currentAccessList = [
                SELECT Id, Learning_File__c, Contact__c, Completion_Status__c, Completion_Date_Time__c
                FROM Learning_Access__c
                WHERE Contact__c = :contactId AND Learning_File__c = :fileId
                LIMIT 1
            ];

            Learning_Access__c currentAccess;
            if (currentAccessList.isEmpty()) {
                currentAccess = new Learning_Access__c(
                    Contact__c = contactId,
                    Learning_File__c = fileId,
                    Access_Status__c = 'Granted',
                    Granted_Date__c = System.Now()
                );
            } else {
                currentAccess = currentAccessList[0];
            }

            currentAccess.Completion_Status__c = 'Completed';
            currentAccess.Completion_Date_Time__c = System.now();
            applyLearningAccessName(currentAccess, currentFile);

            Database.UpsertResult upsertResult = Database.upsert(currentAccess, AccessLevel.SYSTEM_MODE);
            if (!upsertResult.isSuccess()) {
                throw new AuraHandledException('Unable to update Learning Access: ' + upsertResult.getErrors()[0].getMessage());
            }

            Boolean autoAssignNextFile = autoAssignNextFileOverride;
            Boolean autoAssignNextFolder = autoAssignNextFolderOverride;
            if (autoAssignNextFile == null || autoAssignNextFolder == null) {
                List<Assessment_Portal_Config__mdt> configRecords = [
                    SELECT Auto_Assign_Next_File__c, Auto_Assign_Next_Folder__c
                    FROM Assessment_Portal_Config__mdt
                    LIMIT 1
                ];
                if (!configRecords.isEmpty()) {
                    if (autoAssignNextFile == null) {
                        autoAssignNextFile = configRecords[0].Auto_Assign_Next_File__c == true;
                    }
                    if (autoAssignNextFolder == null) {
                        autoAssignNextFolder = configRecords[0].Auto_Assign_Next_Folder__c == true;
                    }
                } else {
                    autoAssignNextFile = false;
                    autoAssignNextFolder = false;
                }
            }

            // ─── Pull every file in this folder, sorted the same way the UI sorts them ───
            List<Learning_File__c> allFolderFiles = [
                SELECT Id, Name, Sort_Order__c, Learning_Folder__c, Owner.Name
                FROM Learning_File__c
                WHERE Learning_Folder__c = :currentFile.Learning_Folder__c
            ];
            allFolderFiles.sort(new FileNaturalComparator());

            Set<Id> folderFileIds = new Set<Id>();
            for (Learning_File__c f : allFolderFiles) {
                folderFileIds.add(f.Id);
            }

            // ─── Source of truth for "is this folder done": check every file's
            // Completion_Status__c directly. No positional inference. ───
            Map<Id, Learning_Access__c> folderAccessByFileId = new Map<Id, Learning_Access__c>();
            for (Learning_Access__c acc : [
                SELECT Id, Learning_File__c, Completion_Status__c
                FROM Learning_Access__c
                WHERE Contact__c = :contactId AND Learning_File__c IN :folderFileIds
            ]) {
                folderAccessByFileId.put(acc.Learning_File__c, acc); 
            }
            // Make sure the completion we just upserted is reflected even if the
            // query above ran before the transaction's own write was visible to it.
            folderAccessByFileId.put(currentFile.Id, currentAccess);

            Boolean allFilesCompletedInFolder = true;
            for (Learning_File__c f : allFolderFiles) {
                Learning_Access__c acc = folderAccessByFileId.get(f.Id);
                if (acc == null || acc.Completion_Status__c != 'Completed') {
                    allFilesCompletedInFolder = false;
                    break;
                }
            }

            if (!allFilesCompletedInFolder && autoAssignNextFile) {
                // ─── Folder isn't finished yet — grant access to the next file
                // in sequence (natural sort order) so it appears unlocked. ───
                Integer currentIndex = -1;
                for (Integer i = 0; i < allFolderFiles.size(); i++) {
                    if (allFolderFiles[i].Id == currentFile.Id) {
                        currentIndex = i;
                        break;
                    }
                }

                Learning_File__c nextFile = (currentIndex >= 0 && currentIndex + 1 < allFolderFiles.size())
                    ? allFolderFiles[currentIndex + 1]
                    : null;

                if (nextFile != null && !folderAccessByFileId.containsKey(nextFile.Id)) {
                    Learning_Access__c nextAccess = new Learning_Access__c(
                        Contact__c = contactId,
                        Learning_File__c = nextFile.Id,
                        Access_Status__c = 'Granted',
                        Completion_Status__c = 'Not Started',
                        Granted_Date__c = System.now(),
                        Date_Time_Opened__c = null
                    );
                    applyLearningAccessName(nextAccess, nextFile);
                    Database.SaveResult insertResult = Database.insert(nextAccess, false, AccessLevel.SYSTEM_MODE);
                    if (!insertResult.isSuccess()) {
                        throw new AuraHandledException(NEXT_ACCESS_LOCKED_MESSAGE);
                    }
                }

                result.put('success', true);
                result.put('message', nextFile != null ? 'File marked complete. Next file loaded.' : 'File marked complete.');
                result.put('nextFileId', nextFile != null ? nextFile.Id : null);
                result.put('nextFileName', nextFile != null ? nextFile.Name : null);
                result.put('nextFolderUnlocked', false);
            } else if (allFilesCompletedInFolder && autoAssignNextFolder) {
                // ─── Every file in this folder is Completed — unlock the next
                // content folder anywhere in the tree. ───

                Learning_File__c firstFileOfNextFolder =
                    findNextContentFolderFirstFile(currentFile.Learning_Folder__c);

                if (firstFileOfNextFolder != null) {
                    List<Learning_Access__c> existingNextFolderAccess = [
                        SELECT Id
                        FROM Learning_Access__c
                        WHERE Contact__c = :contactId AND Learning_File__c = :firstFileOfNextFolder.Id
                        LIMIT 1
                    ];

                    if (existingNextFolderAccess.isEmpty()) {
                        Learning_Access__c nextFolderAccess = new Learning_Access__c(
                            Contact__c = contactId,
                            Learning_File__c = firstFileOfNextFolder.Id,
                            Access_Status__c = 'Granted',
                            Completion_Status__c = 'Not Started',
                            Granted_Date__c = System.now(),
                            Date_Time_Opened__c = null
                        );
                        applyLearningAccessName(nextFolderAccess, firstFileOfNextFolder);
                        Database.SaveResult insertResult = Database.insert(nextFolderAccess, false, AccessLevel.SYSTEM_MODE);
                        if (!insertResult.isSuccess()) {
                            List<String> errorMessages = new List<String>();
                            for (Database.Error err : insertResult.getErrors()) {
                                errorMessages.add(err.getMessage());
                            }
                            ErrorLogger.log(
                                'Unable to grant access to the next learning folder: ' +
                                String.join(errorMessages, '; ')
                            );
                        }

                        if (!insertResult.isSuccess()) {
                            throw new AuraHandledException(NEXT_ACCESS_LOCKED_MESSAGE);
                        }
                    }

                    result.put('success', true);
                    result.put('message', 'File marked complete. Next folder unlocked.');
                    result.put('nextFileId', null);
                    result.put('nextFileName', null);
                    result.put('nextFolderUnlocked', true);
                } else {
                    result.put('success', true);
                    result.put('message', 'File marked complete. No more content in this path.');
                    result.put('nextFileId', null);
                    result.put('nextFileName', null);
                    result.put('nextFolderUnlocked', false);
                }
            } else {
                result.put('success', true);
                result.put('message', 'File marked complete.');
                result.put('nextFileId', null);
                result.put('nextFileName', null);
                result.put('nextFolderUnlocked', false);
            }

            // Include debug payload for clients that cannot read Apex logs
            try {
                // Build pre-order folder list (with names)
                List<Learning_Folder__c> allFoldersList = [
                    SELECT Id, Parent_Folder__c, Name
                    FROM Learning_Folder__c
                    ORDER BY Sort_Order__c NULLS LAST, Name
                ];

                Map<Id, List<Id>> childIdsByParent = new Map<Id, List<Id>>();
                List<Id> rootFolderIds = new List<Id>();
                for (Learning_Folder__c f : allFoldersList) {
                    if (f.Parent_Folder__c == null) {
                        rootFolderIds.add(f.Id);
                    } else {
                        if (!childIdsByParent.containsKey(f.Parent_Folder__c)) {
                            childIdsByParent.put(f.Parent_Folder__c, new List<Id>());
                        }
                        childIdsByParent.get(f.Parent_Folder__c).add(f.Id);
                    }
                }

                List<Id> preOrderFolderIds = new List<Id>();
                for (Id rootId : rootFolderIds) {
                    appendFolderAndDescendantsInPreOrder(rootId, childIdsByParent, preOrderFolderIds);
                }

                // Files and first-file mapping
                List<Learning_File__c> allFiles = [
                    SELECT Id, Name, Sort_Order__c, Learning_Folder__c
                    FROM Learning_File__c
                    WHERE Learning_Folder__c != null
                ];
                allFiles.sort(new FileNaturalComparator());

                Map<Id, Learning_File__c> firstFileByFolder = new Map<Id, Learning_File__c>();
                Map<Id, Integer> fileCounts = new Map<Id, Integer>();
                for (Learning_File__c file : allFiles) {
                    if (!firstFileByFolder.containsKey(file.Learning_Folder__c)) {
                        firstFileByFolder.put(file.Learning_Folder__c, file);
                    }
                    fileCounts.put(file.Learning_Folder__c, fileCounts.containsKey(file.Learning_Folder__c) ? fileCounts.get(file.Learning_Folder__c) + 1 : 1);
                }

                List<Id> contentFolderOrder = new List<Id>();
                for (Id fid : preOrderFolderIds) {
                    if (firstFileByFolder.containsKey(fid)) {
                        contentFolderOrder.add(fid);
                    }
                }

                Map<String, Object> dbg = new Map<String, Object>();
                Map<String, String> folderNames = new Map<String, String>();
                for (Learning_Folder__c f : allFoldersList) {
                    folderNames.put(String.valueOf(f.Id), f.Name);
                }

                Map<String, Integer> fileCountMap = new Map<String, Integer>();
                Map<String, String> firstFileNames = new Map<String, String>();
                for (Id fid : firstFileByFolder.keySet()) {
                    fileCountMap.put(String.valueOf(fid), fileCounts.containsKey(fid) ? fileCounts.get(fid) : 0);
                    firstFileNames.put(String.valueOf(fid), firstFileByFolder.get(fid).Name);
                }

                dbg.put('preOrderFolderIds', preOrderFolderIds);
                dbg.put('contentFolderOrder', contentFolderOrder);
                dbg.put('folderNames', folderNames);
                dbg.put('fileCounts', fileCountMap);
                dbg.put('firstFileNames', firstFileNames);

                Integer currentIdx = -1;
                for (Integer i = 0; i < contentFolderOrder.size(); i++) {
                    if (contentFolderOrder[i] == currentFile.Learning_Folder__c) {
                        currentIdx = i;
                        break;
                    }
                }

                dbg.put('currentIndex', currentIdx);
                dbg.put('currentFolderId', String.valueOf(currentFile.Learning_Folder__c));

                result.put('debugNext', dbg);
            } catch (Exception de) {
                ErrorLogger.log(de);
                result.put('debugNextError', de.getMessage());
            }

        } catch (Exception e) {
            ErrorLogger.log(e);
            String errorMessage = e.getMessage() != null && e.getMessage().contains(NEXT_ACCESS_LOCKED_MESSAGE)
                ? NEXT_ACCESS_LOCKED_MESSAGE
                : 'Error marking file complete: ' + e.getMessage();
            throw new AuraHandledException(errorMessage);
        }

        return result;
    }

    @AuraEnabled
    public static Map<String, Object> repairStalledUnlocks() {
        Map<String, Object> result = new Map<String, Object>();
        Integer foldersUnlocked = 0;
        List<String> details = new List<String>();

        try {
            // ─── All files, grouped by folder, sorted the same way the UI/markFileComplete sort them ───
            List<Learning_File__c> allFiles = [
                SELECT Id, Name, Sort_Order__c, Learning_Folder__c, Owner.Name
                FROM Learning_File__c
                WHERE Learning_Folder__c != null
            ];
            allFiles.sort(new FileNaturalComparator());

            Map<Id, List<Learning_File__c>> filesByFolder = new Map<Id, List<Learning_File__c>>();
            Map<Id, Id> folderIdByFileId = new Map<Id, Id>();
            for (Learning_File__c f : allFiles) {
                if (!filesByFolder.containsKey(f.Learning_Folder__c)) {
                    filesByFolder.put(f.Learning_Folder__c, new List<Learning_File__c>());
                }
                filesByFolder.get(f.Learning_Folder__c).add(f);
                folderIdByFileId.put(f.Id, f.Learning_Folder__c);
            }

            // ─── Every granted access record, for every contact ───
            List<Learning_Access__c> allAccess = [
                SELECT Id, Contact__c, Learning_File__c, Completion_Status__c
                FROM Learning_Access__c
                WHERE Access_Status__c = 'Granted' AND Contact__c != null
            ];

            Map<Id, Map<Id, Learning_Access__c>> accessByContactThenFile = new Map<Id, Map<Id, Learning_Access__c>>();
            for (Learning_Access__c acc : allAccess) {
                if (!accessByContactThenFile.containsKey(acc.Contact__c)) {
                    accessByContactThenFile.put(acc.Contact__c, new Map<Id, Learning_Access__c>());
                }
                accessByContactThenFile.get(acc.Contact__c).put(acc.Learning_File__c, acc);
            }

            List<Learning_Access__c> newAccessToInsert = new List<Learning_Access__c>();

            for (Id contactId : accessByContactThenFile.keySet()) {
                Map<Id, Learning_Access__c> contactAccessByFile = accessByContactThenFile.get(contactId);

                // Which folders has this contact actually reached (has access to >=1 file in)?
                Set<Id> touchedFolderIds = new Set<Id>();
                for (Id fileId : contactAccessByFile.keySet()) {
                    if (folderIdByFileId.containsKey(fileId)) {
                        touchedFolderIds.add(folderIdByFileId.get(fileId));
                    }
                }

                for (Id folderId : touchedFolderIds) {
                    List<Learning_File__c> folderFiles = filesByFolder.get(folderId);
                    if (folderFiles == null || folderFiles.isEmpty()) {
                        continue;
                    }

                    Boolean allCompleted = true;
                    for (Learning_File__c ff : folderFiles) {
                        Learning_Access__c acc = contactAccessByFile.get(ff.Id);
                        if (acc == null || acc.Completion_Status__c != 'Completed') {
                            allCompleted = false;
                            break;
                        }
                    }

                    if (!allCompleted) {
                        continue;
                    }

                    Learning_File__c firstFileOfNext = findNextContentFolderFirstFile(folderId);
                    if (firstFileOfNext == null) {
                        continue; // this was already the last content folder in the tree
                    }
                    if (contactAccessByFile.containsKey(firstFileOfNext.Id)) {
                        continue; // already unlocked, nothing to repair
                    }

                    Learning_Access__c newAccess = new Learning_Access__c(
                        Contact__c = contactId,
                        Learning_File__c = firstFileOfNext.Id,
                        Access_Status__c = 'Granted',
                        Completion_Status__c = 'Not Started',
                        Granted_Date__c = System.now(),
                        Date_Time_Opened__c = null
                    );
                    applyLearningAccessName(newAccess, firstFileOfNext);
                    newAccessToInsert.add(newAccess);
                    // Reflect it locally too, in case of any future lookups within this same run
                    contactAccessByFile.put(firstFileOfNext.Id, newAccess);

                    foldersUnlocked++;
                    details.add(contactId + ' :: folder ' + folderId + ' -> granted file ' + firstFileOfNext.Id);
                }
            }

            Integer insertFailures = 0;
            if (!newAccessToInsert.isEmpty()) {
                List<Database.SaveResult> saveResults = Database.insert(newAccessToInsert, false, AccessLevel.SYSTEM_MODE);
                for (Database.SaveResult sr : saveResults) {
                    if (!sr.isSuccess()) {
                        insertFailures++;
                    }
                }
            }

            result.put('success', true);
            result.put('foldersUnlocked', foldersUnlocked);
            result.put('insertFailures', insertFailures);
            result.put('details', details);

        } catch (Exception e) {
            ErrorLogger.log(e);
            throw new AuraHandledException('Error repairing stalled unlocks: ' + e.getMessage());
        }

        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<RecentFileWrapper> getRecentFiles(Integer limitCount) {
        LearningAccessAdminController.assertTeamMemberAccessAllowed();
        Integer effectiveLimit = (limitCount == null || limitCount <= 0) ? 5 : limitCount;

        Id contactId = getCurrentContactId();
        if (contactId == null) {
            return new List<RecentFileWrapper>();
        }

        List<Learning_Access__c> accesses = [
            SELECT Id, Date_Time_Opened__c, Learning_File__c,
                Learning_File__r.Name,
                Learning_File__r.Mime_Type__c,
                Learning_File__r.Web_View_Link__c
            FROM Learning_Access__c
            WHERE Contact__c = :contactId
            ORDER BY Date_Time_Opened__c DESC
            LIMIT :effectiveLimit
        ];

        List<RecentFileWrapper> results = new List<RecentFileWrapper>();
        for (Learning_Access__c a : accesses) {
            if (a.Learning_File__c == null) {
                continue;
            }
            RecentFileWrapper w = new RecentFileWrapper();
            w.id = a.Learning_File__c;
            w.name = a.Learning_File__r.Name;
            w.mimeType = a.Learning_File__r.Mime_Type__c;
            w.url = a.Learning_File__r.Web_View_Link__c;
            w.lastAccessed = a.Date_Time_Opened__c;
            results.add(w);
        }
        return results;
    }

    private static Learning_File__c findNextContentFolderFirstFile(Id currentFolderId) {
        List<Learning_Folder__c> allFoldersList = [
            SELECT Id, Parent_Folder__c, Name
            FROM Learning_Folder__c
            ORDER BY Sort_Order__c NULLS LAST, Name
        ];

        // Group children by parent; already in Sort_Order__c/Name order from the query above
        Map<Id, List<Id>> childIdsByParent = new Map<Id, List<Id>>();
        List<Id> rootFolderIds = new List<Id>();

        for (Learning_Folder__c f : allFoldersList) {
            if (f.Parent_Folder__c == null) {
                rootFolderIds.add(f.Id);
            } else {
                if (!childIdsByParent.containsKey(f.Parent_Folder__c)) {
                    childIdsByParent.put(f.Parent_Folder__c, new List<Id>());
                }
                childIdsByParent.get(f.Parent_Folder__c).add(f.Id);
            }
        }

        // Flatten the whole tree into pre-order (folder, then its children, then next sibling)
        List<Id> preOrderFolderIds = new List<Id>();
        for (Id rootId : rootFolderIds) {
            appendFolderAndDescendantsInPreOrder(rootId, childIdsByParent, preOrderFolderIds);
        }

        // First file (by Sort_Order__c, then natural name order) for every folder that has files
        List<Learning_File__c> allFiles = [
            SELECT Id, Name, Sort_Order__c, Learning_Folder__c
            FROM Learning_File__c
            WHERE Learning_Folder__c != null
        ];
        allFiles.sort(new FileNaturalComparator());

        Map<Id, Learning_File__c> firstFileByFolder = new Map<Id, Learning_File__c>();
        for (Learning_File__c file : allFiles) {
            if (!firstFileByFolder.containsKey(file.Learning_Folder__c)) {
                firstFileByFolder.put(file.Learning_Folder__c, file);
            }
        }

        // Filter the pre-order folder list down to only folders that actually have files,
        // preserving order — this is the sequence a learner should move through
        List<Id> contentFolderOrder = new List<Id>();
        for (Id fid : preOrderFolderIds) {
            if (firstFileByFolder.containsKey(fid)) {
                contentFolderOrder.add(fid);
            }
        }

        Integer currentIdx = -1;
        for (Integer i = 0; i < contentFolderOrder.size(); i++) {
            if (contentFolderOrder[i] == currentFolderId) {
                currentIdx = i;
                break;
            }
        }

        if (currentIdx == -1 || currentIdx + 1 >= contentFolderOrder.size()) {
            return null;
        }

        Id nextFolderId = contentFolderOrder[currentIdx + 1];

        Learning_File__c nextFile = firstFileByFolder.get(nextFolderId);

        return nextFile;
    }

    @AuraEnabled
    public static Map<String, Object> debugNextContentFolder(Id currentFolderId) {
        return getNextContentFolderDiagnostics(currentFolderId);
    }

    @AuraEnabled
    public static Map<String, Object> getNextContentFolderDiagnostics(Id currentFolderId) {
        Map<String, Object> diagnostics = new Map<String, Object>();

        // Build pre-order folder list
        List<Learning_Folder__c> orderedFolders = [
            SELECT Id, Name, Parent_Folder__c
            FROM Learning_Folder__c
            ORDER BY Sort_Order__c NULLS LAST, Name
        ];

        Map<Id, List<Id>> childFolderIdsByParentId = new Map<Id, List<Id>>();
        List<Id> rootFolderIds = new List<Id>();
        for (Learning_Folder__c folder : orderedFolders) {
            if (folder.Parent_Folder__c == null) {
                rootFolderIds.add(folder.Id);
            } else {
                if (!childFolderIdsByParentId.containsKey(folder.Parent_Folder__c)) {
                    childFolderIdsByParentId.put(folder.Parent_Folder__c, new List<Id>());
                }
                childFolderIdsByParentId.get(folder.Parent_Folder__c).add(folder.Id);
            }
        }

        List<Id> folderIdsInPreOrder = new List<Id>();
        for (Id rootId : rootFolderIds) {
            appendFolderAndDescendantsInPreOrder(rootId, childFolderIdsByParentId, folderIdsInPreOrder);
        }

        // First file per folder
        List<Learning_File__c> allFiles = [
            SELECT Id, Name, Sort_Order__c, Learning_Folder__c
            FROM Learning_File__c
            WHERE Learning_Folder__c != null
        ];
        allFiles.sort(new FileNaturalComparator());

        Map<Id, Learning_File__c> firstFileByFolderId = new Map<Id, Learning_File__c>();
        for (Learning_File__c file : allFiles) {
            if (!firstFileByFolderId.containsKey(file.Learning_Folder__c)) {
                firstFileByFolderId.put(file.Learning_Folder__c, file);
            }
        }

        List<Id> folderIdsWithContentInOrder = new List<Id>();
        for (Id folderId : folderIdsInPreOrder) {
            if (firstFileByFolderId.containsKey(folderId)) {
                folderIdsWithContentInOrder.add(folderId);
            }
        }

        // Build human-readable maps for the client to consume
        Map<String, String> folderNameById = new Map<String, String>();
        for (Learning_Folder__c folder : orderedFolders) {
            folderNameById.put(String.valueOf(folder.Id), folder.Name);
        }

        // Count files per folder and capture first-file names
        Map<String, Integer> fileCountByFolderId = new Map<String, Integer>();
        Map<String, String> firstFileNameByFolderId = new Map<String, String>();
        for (Learning_File__c file : allFiles) {
            String folderId = String.valueOf(file.Learning_Folder__c);
            fileCountByFolderId.put(
                folderId,
                fileCountByFolderId.containsKey(folderId) ? fileCountByFolderId.get(folderId) + 1 : 1
            );
            if (!firstFileNameByFolderId.containsKey(folderId)) {
                firstFileNameByFolderId.put(folderId, file.Name);
            }
        }

        diagnostics.put('preOrderFolderIds', folderIdsInPreOrder);
        diagnostics.put('contentFolderOrder', folderIdsWithContentInOrder);
        diagnostics.put('folderNames', folderNameById);
        diagnostics.put('fileCounts', fileCountByFolderId);
        diagnostics.put('firstFileNames', firstFileNameByFolderId);

        Integer currentFolderIndex = -1;
        for (Integer folderIndex = 0; folderIndex < folderIdsWithContentInOrder.size(); folderIndex++) {
            if (folderIdsWithContentInOrder[folderIndex] == currentFolderId) {
                currentFolderIndex = folderIndex;
                break;
            }
        }

        diagnostics.put('currentIndex', currentFolderIndex);
        diagnostics.put('currentFolderId', currentFolderId);

        if (currentFolderIndex == -1 || currentFolderIndex + 1 >= folderIdsWithContentInOrder.size()) {
            diagnostics.put('nextFolderId', null);
            diagnostics.put('nextFileId', null);
            diagnostics.put('nextFileName', null);
            return diagnostics;
        }

        Id nextFolderId = folderIdsWithContentInOrder[currentFolderIndex + 1];
        Learning_File__c nextFile = firstFileByFolderId.get(nextFolderId);
        diagnostics.put('nextFolderId', String.valueOf(nextFolderId));
        if (nextFile != null) {
            diagnostics.put('nextFileId', String.valueOf(nextFile.Id));
            diagnostics.put('nextFileName', nextFile.Name);
        } else {
            diagnostics.put('nextFileId', null);
            diagnostics.put('nextFileName', null);
        }

        return diagnostics;
    }

    private static void appendFolderAndDescendantsInPreOrder(
        Id folderId,
        Map<Id, List<Id>> childFolderIdsByParentId,
        List<Id> orderedFolderIds
    ) {
        orderedFolderIds.add(folderId);
        if (childFolderIdsByParentId.containsKey(folderId)) {
            for (Id childFolderId : childFolderIdsByParentId.get(folderId)) {
                appendFolderAndDescendantsInPreOrder(childFolderId, childFolderIdsByParentId, orderedFolderIds);
            }
        }
    }

    /**
     * Records the first-opened timestamp for a file. Resolves (or creates) the
     * Learning_Access__c record by contact+fileId — consistent with markFileComplete.
     */
    @AuraEnabled
    public static Map<String, Object> recordFileOpened(String fileId) {
        Map<String, Object> result = new Map<String, Object>();

        try {
            LearningAccessAdminController.assertTeamMemberAccessAllowed();
            if (String.isBlank(fileId)) {
                throw new AuraHandledException('File Id is required');
            }

            Id contactId = getCurrentContactId();

            if (contactId == null) {
                // Admins/guests without a contact: nothing to persist
                result.put('success', true);
                result.put('message', 'Admin access - no tracking required');
                result.put('dateTimeOpened', System.now());
                return result;
            }

            List<Learning_File__c> fileRecords = [
                SELECT Id, Name, Owner.Name
                FROM Learning_File__c
                WHERE Id = :fileId
                LIMIT 1
            ];
            Learning_File__c fileRecord = !fileRecords.isEmpty() ? fileRecords[0] : null;

            List<Learning_Access__c> existingAccess = [
                SELECT Id, Date_Time_Opened__c
                FROM Learning_Access__c
                WHERE Contact__c = :contactId AND Learning_File__c = :fileId
                LIMIT 1
            ];

            Learning_Access__c access;
            Boolean isExistingAccess = !existingAccess.isEmpty();
            if (isExistingAccess) {
                access = existingAccess[0];
            } else {
                access = new Learning_Access__c(
                    Contact__c = contactId,
                    Learning_File__c = fileId,
                    Access_Status__c = 'Granted',
                    Completion_Status__c = 'Not Started',
                    Granted_Date__c = System.now()
                );
            }

            applyLearningAccessName(access, fileRecord);
            if (isExistingAccess) {
                Database.SaveResult updateResult = Database.update(access, false, AccessLevel.SYSTEM_MODE);
                if (!updateResult.isSuccess()) {
                    throw new AuraHandledException('Unable to update Learning Access: ' + updateResult.getErrors()[0].getMessage());
                }
            } else {
                Database.SaveResult insertResult = Database.insert(access, false, AccessLevel.SYSTEM_MODE);
                if (!insertResult.isSuccess()) {
                    throw new AuraHandledException('Unable to create Learning Access: ' + insertResult.getErrors()[0].getMessage());
                }
            }

            if (access.Date_Time_Opened__c == null) {
                access.Date_Time_Opened__c = System.now();
                Database.SaveResult updateResult = Database.update(access, false, AccessLevel.SYSTEM_MODE);
                if (!updateResult.isSuccess()) {
                    throw new AuraHandledException('Unable to update Learning Access: ' + updateResult.getErrors()[0].getMessage());
                }
                result.put('message', 'File opened timestamp recorded');
            } else {
                result.put('message', 'File already opened');
            }

            result.put('success', true);
            result.put('dateTimeOpened', access.Date_Time_Opened__c);
            result.put('learningAccessId', access.Id);
        } catch (Exception e) {
            ErrorLogger.log(e);
            throw new AuraHandledException('Error recording file open: ' + e.getMessage());
        }

        return result;
    }

    @AuraEnabled
    public static Map<String, Object> submitFileFeedback(String fileId, String commentText) {
        Map<String, Object> result = new Map<String, Object>();

        try {
            LearningAccessAdminController.assertTeamMemberAccessAllowed();
            if (String.isBlank(fileId)) {
                throw new AuraHandledException('File Id is required');
            }
            if (String.isBlank(commentText)) {
                throw new AuraHandledException('Feedback comment is required');
            }

            Id contactId = getCurrentContactId();
            Id queueId = getFeedbackQueueId();

            List<Learning_File__c> fileList = [
                SELECT Name 
                FROM Learning_File__c 
                WHERE Id = :fileId 
                LIMIT 1
            ];
            String fileName = !fileList.isEmpty() ? fileList[0].Name : 'Learning File';

            String recordUrl = getExperienceSiteDetailUrl(fileId);

            String subjectText = 'Feedback: ' + fileName;
            if (subjectText.length() > 255) {
                subjectText = subjectText.substring(0, 252) + '...';
            }

            String fullDescription = 'Related Record: ' + fileName + '\n' +
                                    'Record Link: ' + recordUrl + '\n\n' +
                                    'Feedback:\n' + commentText;

            Case feedbackCase = new Case(
                Subject      = subjectText,
                Description  = fullDescription,
                Status       = 'New',
                Type         = 'Learning Content Feedback'
            );

            if (contactId != null) {
                feedbackCase.ContactId = contactId;
            }
            if (queueId != null) {
                feedbackCase.OwnerId = queueId;
            }

            Database.SaveResult insertResult = Database.insert(feedbackCase, false, AccessLevel.SYSTEM_MODE);
            if (!insertResult.isSuccess()) {
                throw new AuraHandledException('Unable to submit feedback: ' + insertResult.getErrors()[0].getMessage());
            }

            Id newCaseId = insertResult.getId();

            if (queueId != null) {
                sendQueueNotification(queueId, newCaseId, commentText);
            }

            result.put('success', true);
            result.put('caseId', newCaseId);
            result.put('taskId', newCaseId);

        } catch (Exception e) {
            ErrorLogger.log(e);
            throw new AuraHandledException('Error submitting feedback: ' + e.getMessage());
        }

        return result;
    }

    private static Id getFeedbackQueueId() {
    List<Group> queues = Database.query(
        'SELECT Id FROM Group WHERE Type = \'Queue\' AND DeveloperName = :QUEUE_DEV_NAME LIMIT 1',
        AccessLevel.SYSTEM_MODE
    );
    return queues.isEmpty() ? null : queues[0].Id;
}

    private static void sendQueueNotification(Id queueId, Id taskId, String commentText) {
    try {
        List<CustomNotificationType> notifTypes = Database.query(
            'SELECT Id FROM CustomNotificationType WHERE DeveloperName = :NOTIFICATION_TYPE_DEV_NAME LIMIT 1',
            AccessLevel.SYSTEM_MODE
        );
        if (notifTypes.isEmpty()) {
            return;
        }

        Set<String> recipientIds = new Set<String>();
        List<GroupMember> members = Database.query(
            'SELECT UserOrGroupId FROM GroupMember WHERE GroupId = :queueId',
            AccessLevel.SYSTEM_MODE
        );
        for (GroupMember gm : members) {
            recipientIds.add(gm.UserOrGroupId);
        }

        if (recipientIds.isEmpty()) {
            return;
        }

        String bodyPreview = commentText.length() > 100 
            ? commentText.substring(0, 100) + '...' 
            : commentText;

        Messaging.CustomNotification notification = new Messaging.CustomNotification();
        notification.setTitle('New Learning File Feedback');
        notification.setBody(bodyPreview);
        notification.setNotificationTypeId(notifTypes[0].Id);
        notification.setTargetId(taskId);

        notification.send(recipientIds);

    } catch (Exception e) {
        ErrorLogger.log(e);
    }
}
    public static String getExperienceSiteDetailUrl(Id recordId) {
        Id networkId = Network.getNetworkId();

        if (networkId != null) {
            String loginUrl = Network.getLoginUrl(networkId);
            if (String.isNotBlank(loginUrl)) {
                String siteBase = '';
                if (loginUrl.contains('/s/')) {
                    siteBase = loginUrl.substringBefore('/s/');
                } else if (loginUrl.contains('/login')) {
                    siteBase = loginUrl.substringBefore('/login');
                } else {
                    siteBase = loginUrl.removeEnd('/');
                }
                return siteBase + '/s/detail/' + recordId;
            }
        }

        // Fallback if executing outside Community context (e.g., standard internal admin)
        return URL.getOrgDomainUrl().toExternalForm() + '/' + recordId;
    }

}