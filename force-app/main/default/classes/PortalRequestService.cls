public with sharing class PortalRequestService {

    private static final String QUEUE_HR_DEV_NAME = 'HR_Related_Query_Queue';
    private static final String QUEUE_MANAGER_DEV_NAME = 'Manager_Related_Query_Queue';
    private static final String NOTIFICATION_TYPE_DEV_NAME = 'Task_Assigned_to_Queue';
    private static final String TYPE_HR = 'HR Related Query';
    private static final String TYPE_MANAGER = 'Manager Related Query';

    private static final String STATUS_NEW = 'New';
    private static final String STATUS_WORKING = 'Working';
    private static final String STATUS_CLOSED = 'Closed';

    public class RequestResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Id caseId;
        @AuraEnabled public String message;
    }

    public class CommentResult {
        @AuraEnabled public Id id;
        @AuraEnabled public String commentBody;
        @AuraEnabled public String authorName;
        @AuraEnabled public DateTime createdDate;
    }

    @AuraEnabled
    public static RequestResult raiseRequest(
        String requestType,
        String subject,
        String description
    ) {
        RequestResult result = new RequestResult();

        try {
            if (String.isBlank(description)) {
                throw new AuraHandledException('Please describe your request.');
            }
            if (requestType != TYPE_HR && requestType != TYPE_MANAGER) {
                throw new AuraHandledException('Please select a valid request type.');
            }

            String effectiveSubject = String.isNotBlank(subject)
                ? subject
                : ('Portal Request: ' + requestType);

            Id contactId = getCurrentContactId();
            String queueDevName = (requestType == TYPE_HR) ? QUEUE_HR_DEV_NAME : QUEUE_MANAGER_DEV_NAME;
            Id queueId = getQueueId(queueDevName);

            Case c = new Case(
                Subject = effectiveSubject,
                Description = description,
                Status = STATUS_NEW,
                Type = requestType
            );
            if (contactId != null) c.ContactId = contactId;
            if (queueId != null) c.OwnerId = queueId;

            Database.SaveResult sr = Database.insert(c, false, AccessLevel.SYSTEM_MODE);
            if (!sr.isSuccess()) {
                throw new AuraHandledException('Unable to submit request: ' + sr.getErrors()[0].getMessage());
            }

            if (queueId != null) {
                sendQueueNotification(queueId, sr.getId(), description);
            }

            sendRoutedEmail(contactId, requestType, effectiveSubject, description);

            result.success = true;
            result.caseId = sr.getId();
            result.message = 'Your request has been submitted.';
            return result;
        } catch (Exception e) {
            ErrorLogger.log(e);
            AuraHandledException ah = new AuraHandledException('Unable to submit request: ' + e.getMessage());
            ah.setMessage('Unable to submit request: ' + e.getMessage());
            throw ah;
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Case> getMyRequests() {
        Id contactId = getCurrentContactId();
        if (contactId == null) {
            return new List<Case>();
        }
        return [
            SELECT Id, Subject, Type, Status, CreatedDate, Description
            FROM Case
            WHERE ContactId = :contactId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    // Returns requests in the queues the current user belongs to,
    // excluding requests raised by the current user's own Contact.
    @AuraEnabled(cacheable=true)
    public static List<Case> getQueueRequests() {
        Set<Id> queueIds = getMemberQueueIds(UserInfo.getUserId());
        if (queueIds.isEmpty()) {
            return new List<Case>();
        }

        Id myContactId = getCurrentContactId();

        // User has no Contact (e.g. internal user): nothing to exclude
        if (myContactId == null) {
            return [
                SELECT Id, Subject, Type, Status, CreatedDate, Description,
                    Contact.Name, Contact.Id, Contact.Email
                FROM Case
                WHERE OwnerId IN :queueIds
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC
            ];
        }

        return [
            SELECT Id, Subject, Type, Status, CreatedDate, Description,
                Contact.Name, Contact.Id, Contact.Email
            FROM Case
            WHERE OwnerId IN :queueIds
            AND (ContactId = null OR ContactId != :myContactId)
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    @AuraEnabled
    public static void updateRequestStatus(Id caseId, String newStatus) {
        if (caseId == null) {
            throw new AuraHandledException('Case ID is required.');
        }

        List<String> allowedStatuses = new List<String>{ STATUS_NEW, STATUS_WORKING, STATUS_CLOSED };
        if (String.isBlank(newStatus) || !allowedStatuses.contains(newStatus)) {
            throw new AuraHandledException('Invalid status value.');
        }

        try {
            assertQueueAccess(caseId);

            Case c = new Case(
                Id = caseId,
                Status = newStatus
            );
            Database.update(c, true, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            ErrorLogger.log(e);
            throw new AuraHandledException('Unable to update status: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<CommentResult> getCaseComments(Id caseId) {
        if (caseId == null) {
            throw new AuraHandledException('Case ID is required.');
        }
        assertCaseAccess(caseId);

        List<CaseComment> comments = [
            SELECT Id, CommentBody, CreatedDate, CreatedBy.Name
            FROM CaseComment
            WHERE ParentId = :caseId AND IsPublished = true
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC
        ];

        List<CommentResult> results = new List<CommentResult>();
        for (CaseComment cc : comments) {
            CommentResult r = new CommentResult();
            r.id = cc.Id;
            r.commentBody = cc.CommentBody;
            r.authorName = cc.CreatedBy != null ? cc.CreatedBy.Name : null;
            r.createdDate = cc.CreatedDate;
            results.add(r);
        }
        return results;
    }

    @AuraEnabled
    public static void addCaseComment(Id caseId, String commentBody) {
        if (caseId == null) {
            throw new AuraHandledException('Case ID is required.');
        }
        if (String.isBlank(commentBody)) {
            throw new AuraHandledException('Comment cannot be empty.');
        }

        try {
            assertCaseAccess(caseId);

            CaseComment cc = new CaseComment(
                ParentId = caseId,
                CommentBody = commentBody,
                IsPublished = true
            );
            Database.insert(cc, true, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            ErrorLogger.log(e);
            throw new AuraHandledException('Unable to add comment: ' + e.getMessage());
        }
    }

    // Atomic combined operation: updates status and/or adds a comment in a single transaction
    @AuraEnabled
    public static void saveRequestAndComment(Id caseId, String newStatus, String commentBody) {
        if (caseId == null) {
            throw new AuraHandledException('Case ID is required.');
        }

        List<String> allowedStatuses = new List<String>{ STATUS_NEW, STATUS_WORKING, STATUS_CLOSED };
        if (String.isNotBlank(newStatus) && !allowedStatuses.contains(newStatus)) {
            throw new AuraHandledException('Invalid status value.');
        }

        try {
            assertQueueAccess(caseId);

            // 1. Update Case Status only if provided
            if (String.isNotBlank(newStatus)) {
                Case c = new Case(
                    Id = caseId,
                    Status = newStatus
                );
                Database.update(c, true, AccessLevel.SYSTEM_MODE);
            }

            // 2. Insert Case Comment only if text was provided
            if (String.isNotBlank(commentBody) && String.isNotBlank(commentBody.trim())) {
                CaseComment cc = new CaseComment(
                    ParentId = caseId,
                    CommentBody = commentBody.trim(),
                    IsPublished = true
                );
                Database.insert(cc, true, AccessLevel.SYSTEM_MODE);
            }
        } catch (Exception e) {
            ErrorLogger.log(e);
            AuraHandledException ah = new AuraHandledException(e.getMessage());
            ah.setMessage(e.getMessage());
            throw ah;
        }
    }

    // ===== Access checks =====
    private static void assertCaseAccess(Id caseId) {
        Id contactId = getCurrentContactId();
        Set<Id> queueIds = getMemberQueueIds(UserInfo.getUserId());

        String query = 'SELECT Id FROM Case WHERE Id = :caseId AND (OwnerId IN :queueIds';
        if (contactId != null) {
            query += ' OR ContactId = :contactId';
        }
        query += ')';

        List<Case> matches = Database.query(query, AccessLevel.SYSTEM_MODE);
        if (matches.isEmpty()) {
            throw new AuraHandledException('You do not have access to this request.');
        }
    }

    // Queue members may work a case only if it is in their queue
    // and was not raised by their own Contact.
    private static void assertQueueAccess(Id caseId) {
        Set<Id> queueIds = getMemberQueueIds(UserInfo.getUserId());
        Id myContactId = getCurrentContactId();

        String query = 'SELECT Id FROM Case WHERE Id = :caseId AND OwnerId IN :queueIds';
        if (myContactId != null) {
            query += ' AND (ContactId = null OR ContactId != :myContactId)';
        }

        List<Case> matches = Database.query(query, AccessLevel.SYSTEM_MODE);
        if (matches.isEmpty()) {
            throw new AuraHandledException('You do not have access to update this request.');
        }
    }

    // ===== Helpers =====
    private static void sendRoutedEmail(Id contactId, String requestType, String subject, String description) {
        try {
            if (contactId == null) {
                return;
            }

            Contact requesterContact = [
                SELECT Name, HR__c, HR_Email__c, Manager__c, Manager_Email__c
                FROM Contact
                WHERE Id = :contactId
                WITH SYSTEM_MODE
                LIMIT 1
            ];

            List<String> toAddresses = new List<String>();
            List<String> ccAddresses = new List<String>();

            if (requestType == TYPE_HR) {
                if (requesterContact.HR__c == null || String.isBlank(requesterContact.HR_Email__c)) {
                    return;
                }
                toAddresses.add(requesterContact.HR_Email__c);
                if (requesterContact.Manager__c != null && String.isNotBlank(requesterContact.Manager_Email__c)) {
                    ccAddresses.add(requesterContact.Manager_Email__c);
                }
            } else if (requestType == TYPE_MANAGER) {
                if (requesterContact.Manager__c == null || String.isBlank(requesterContact.Manager_Email__c)) {
                    return;
                }
                toAddresses.add(requesterContact.Manager_Email__c);
            }

            if (toAddresses.isEmpty()) {
                return;
            }

            String emailBody = 'A new portal request has been submitted.\n\n' +
                'From: ' + requesterContact.Name + '\n' +
                'Type: ' + requestType + '\n\n' +
                'Description:\n' + description;

            EmailEventPublisher.publishEmail(
                toAddresses,
                ccAddresses.isEmpty() ? null : ccAddresses,
                subject,
                emailBody
            );

        } catch (Exception e) {
            ErrorLogger.log(e);
        }
    }

    private static Id getCurrentContactId() {
        if (UserInfo.getUserType() == 'Guest') return null;
        try {
            List<User> users = [SELECT ContactId FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
            return !users.isEmpty() ? users[0].ContactId : null;
        } catch (Exception e) {
            ErrorLogger.log(e);
            return null;
        }
    }

    private static Id getQueueId(String devName) {
        List<Group> queues = Database.query(
            'SELECT Id FROM Group WHERE Type = \'Queue\' AND DeveloperName = :devName LIMIT 1',
            AccessLevel.SYSTEM_MODE
        );
        return queues.isEmpty() ? null : queues[0].Id;
    }

    private static Set<Id> getMemberQueueIds(Id userId) {
        Set<Id> queueIds = new Set<Id>();
        List<GroupMember> members = Database.query(
            'SELECT GroupId FROM GroupMember WHERE UserOrGroupId = :userId AND Group.Type = \'Queue\'',
            AccessLevel.SYSTEM_MODE
        );
        for (GroupMember gm : members) queueIds.add(gm.GroupId);
        return queueIds;
    }

    private static void sendQueueNotification(Id queueId, Id caseId, String commentText) {
        try {
            List<CustomNotificationType> notifTypes = Database.query(
                'SELECT Id FROM CustomNotificationType WHERE DeveloperName = :NOTIFICATION_TYPE_DEV_NAME LIMIT 1',
                AccessLevel.SYSTEM_MODE
            );
            if (notifTypes.isEmpty()) return;

            Set<String> recipientIds = new Set<String>();
            List<GroupMember> members = Database.query(
                'SELECT UserOrGroupId FROM GroupMember WHERE GroupId = :queueId',
                AccessLevel.SYSTEM_MODE
            );
            for (GroupMember gm : members) recipientIds.add(gm.UserOrGroupId);
            if (recipientIds.isEmpty()) return;

            String bodyPreview = commentText.length() > 100 ? commentText.substring(0, 100) + '...' : commentText;

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setTitle('New Request Assigned');
            notification.setBody(bodyPreview);
            notification.setNotificationTypeId(notifTypes[0].Id);
            notification.setTargetId(caseId);
            notification.send(recipientIds);

        } catch (Exception e) {
            ErrorLogger.log(e);
        }
    }
}