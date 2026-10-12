public without sharing class PortalRequestMentorAccess {
    private static final String LEARNING_ACCESS_REQUEST_SUBJECT_PREFIX =
        'Learning access request:';

    public static List<Case> getAssignedLearningRequests(Id mentorId, Id excludedContactId) {
        Set<Id> mentoredContactIds = getMentoredContactIds(mentorId);
        if (mentoredContactIds.isEmpty()) {
            return new List<Case>();
        }

        String subjectPrefix = LEARNING_ACCESS_REQUEST_SUBJECT_PREFIX + '%';
        return [
            SELECT Id, Subject, Type, Status, CreatedDate, Description,
                Contact.Name, Contact.Id, Contact.Email
            FROM Case
            WHERE ContactId IN :mentoredContactIds
              AND Type = 'Other'
              AND Subject LIKE :subjectPrefix
              AND (ContactId = null OR ContactId != :excludedContactId)
            WITH SYSTEM_MODE
        ];
    }

    public static Case getAssignedLearningRequest(Id caseId, Id mentorId) {
        String subjectPrefix = LEARNING_ACCESS_REQUEST_SUBJECT_PREFIX + '%';
        List<Case> requests = [
            SELECT Id, Subject, Type, Status, CreatedDate, Description,
                Contact.Name, Contact.Id, Contact.Email
            FROM Case
            WHERE Id = :caseId
              AND Type = 'Other'
              AND Subject LIKE :subjectPrefix
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (requests.isEmpty()
            || !getMentoredContactIds(mentorId).contains(requests[0].ContactId)) {
            return null;
        }
        return requests[0];
    }

    public static Boolean isAssignedLearningRequest(Id caseId, Id mentorId) {
        List<Case> requests = [
            SELECT Id, ContactId, Subject, Type
            FROM Case
            WHERE Id = :caseId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (requests.isEmpty()) {
            return false;
        }

        Case request = requests[0];
        return request.ContactId != null
            && request.Type == 'Other'
            && request.Subject != null
            && request.Subject.startsWith(LEARNING_ACCESS_REQUEST_SUBJECT_PREFIX)
            && getMentoredContactIds(mentorId).contains(request.ContactId);
    }

    public static void updateAssignedLearningRequest(Id caseId, Id mentorId, String status) {
        if (!isAssignedLearningRequest(caseId, mentorId)) {
            throw new AuraHandledException('You do not have access to update this request.');
        }
        Database.update(
            new Case(Id = caseId, Status = status),
            true,
            AccessLevel.SYSTEM_MODE
        );
    }

    public static void addAssignedLearningComment(Id caseId, Id mentorId, String commentBody) {
        if (!isAssignedLearningRequest(caseId, mentorId)) {
            throw new AuraHandledException('You do not have access to this request.');
        }
        Database.insert(
            new CaseComment(
                ParentId = caseId,
                CommentBody = commentBody,
                IsPublished = true
            ),
            true,
            AccessLevel.SYSTEM_MODE
        );
    }

    public static List<CaseComment> getAssignedLearningRequestComments(
        Id caseId,
        Id mentorId
    ) {
        if (!isAssignedLearningRequest(caseId, mentorId)) {
            throw new AuraHandledException('You do not have access to this request.');
        }
        return [
            SELECT Id, CommentBody, CreatedDate, CreatedBy.Name
            FROM CaseComment
            WHERE ParentId = :caseId AND IsPublished = true
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC
        ];
    }

    private static Set<Id> getMentoredContactIds(Id mentorId) {
        Set<Id> contactIds = new Set<Id>();
        for (Contact learner : [
            SELECT Id
            FROM Contact
            WHERE Mentor__c = :mentorId
            WITH SYSTEM_MODE
        ]) {
            contactIds.add(learner.Id);
        }
        return contactIds;
    }
}