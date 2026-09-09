public class AssignmentService {
    private static final String QUEUE_DEV_NAME = 'Learning_File_Review_Queue';
    private static final String NOTIFICATION_TYPE_DEV_NAME = 'Task_Assigned_to_Queue';

    @AuraEnabled(cacheable=true)
    public static List<Category__c> getEligibleCategories() {
        Id userId = UserInfo.getUserId();
        User currentUser = [SELECT ContactId FROM User WHERE Id = :userId LIMIT 1];
        Id contactId = currentUser.ContactId;

        if (contactId == null) {
            return [SELECT Id, Name FROM Category__c ORDER BY Name ASC]; // admin preview
        }

        Set<Id> categoryIdsWithAccess = new Set<Id>();
        for (Assignment_Eligibility__c elig : [
            SELECT Assignment__r.Category__c
            FROM Assignment_Eligibility__c
            WHERE Contact__c = :contactId
            AND Eligibility_Status__c IN ('Eligible', 'Completed')
        ]) {
            categoryIdsWithAccess.add(elig.Assignment__r.Category__c);
        }

        if (categoryIdsWithAccess.isEmpty()) {
            return new List<Category__c>();
        }
        return [SELECT Id, Name FROM Category__c WHERE Id IN :categoryIdsWithAccess ORDER BY Name ASC];
    }

    @AuraEnabled
    public static List<Map<String, Object>> getAssignmentsForCategory(Id categoryId) {
        Id userId = UserInfo.getUserId();
        User currentUser = [SELECT ContactId FROM User WHERE Id = :userId LIMIT 1];
        Id contactId = currentUser.ContactId;

        List<Assignment__c> allAssignments = [
            SELECT Id, Name, Total_Question_Count__c,Time_Limit_Minutes__c 
            FROM Assignment__c
            WHERE Category__c = :categoryId ORDER BY Sequence__c ASC
        ];

        // Map assignment Id -> real Eligibility_Status__c value, not just a boolean.
        // Possible values seen here: 'Eligible', 'Completed', 'In Progress' (if you use it).
        // Anything NOT in this map means the user has no eligibility record at all
        // for that assignment, which we treat as 'Locked' on the UI side.
        Map<Id, String> statusByAssignmentId = new Map<Id, String>();
        if (contactId != null) {
            for (Assignment_Eligibility__c eligibility : [
                SELECT Assignment__c, Eligibility_Status__c
                FROM Assignment_Eligibility__c
                WHERE Contact__c = :contactId
                AND Assignment__r.Category__c = :categoryId
                AND Eligibility_Status__c IN ('Eligible', 'Completed', 'In Progress')
            ]) {
                statusByAssignmentId.put(eligibility.Assignment__c, eligibility.Eligibility_Status__c);
            }
        }

        List<Map<String, Object>> assignmentsWithStatus = new List<Map<String, Object>>();
        for (Assignment__c asm : allAssignments) {
            Map<String, Object> asmMap = new Map<String, Object>();
            asmMap.put('Id', asm.Id);
            asmMap.put('Name', asm.Name);
            asmMap.put('Total_Question_Count__c', asm.Total_Question_Count__c);
            asmMap.put('Time_Limit_Minutes__c', asm.Time_Limit_Minutes__c);

            String rawStatus;
            if (contactId == null) {
                // Internal/admin preview context: treat everything as open
                rawStatus = 'Eligible';
            } else if (statusByAssignmentId.containsKey(asm.Id)) {
                rawStatus = statusByAssignmentId.get(asm.Id);
            } else {
                continue;
            }

            asmMap.put('status', rawStatus);
            // Keep isDisabled for backward compatibility with existing button disabled binding.
            // Anything other than 'Eligible' should be unclickable.
            asmMap.put('isDisabled', rawStatus != 'Eligible');

            assignmentsWithStatus.add(asmMap);
        }

        return assignmentsWithStatus;
    }

    @AuraEnabled(cacheable=true)
    public static List<Assignment_Question__c> getAssignmentQuestions(Id assignmentId) {
        return [
            SELECT Id, Question_Text__c, Max_Points__c
            FROM Assignment_Question__c
            WHERE Assignment__c = :assignmentId
            ORDER BY CreatedDate ASC
        ];
    }

    /**
     * @param assignmentId The ID of the assignment being submitted
     * @param answersJson  JSON string mapping Question Id -> answer text
     */
    @AuraEnabled
    public static Id submitAssignment(Id assignmentId, String answersJson,  Boolean isLocked, String lockReason, Integer violationCount) {
        try {
            Map<Id, String> answersMap = (Map<Id, String>) JSON.deserialize(answersJson, Map<Id, String>.class);

            Id userId = UserInfo.getUserId();
            User currentUser = [SELECT ContactId FROM User WHERE Id = :userId LIMIT 1];
            Id contactId = currentUser.ContactId;

            List<Assignment_Eligibility__c> eligibilityRecords = [
                SELECT Id, Current_Attempt_Number__c, Eligibility_Status__c,
                       Contact__r.Name,
                       Assignment__r.Name, Assignment__r.Category__c, Assignment__r.Sequence__c
                FROM Assignment_Eligibility__c
                WHERE Assignment__c = :assignmentId
                AND Eligibility_Status__c = 'Eligible'
                LIMIT 1
            ];

            if (eligibilityRecords.isEmpty()) {
                AuraHandledException noEligException = new AuraHandledException('No active eligibility found for this assignment.');
                noEligException.setMessage('No active eligibility found for this assignment.');
                throw noEligException;
            }
            Assignment_Eligibility__c lockGate = eligibilityRecords[0];

            // Current_Attempt_Number__c is not maintained by the admin reset process
            // (it only flips Eligibility_Status__c back to 'Eligible'), so it can't be
            // trusted as the source of truth for "which attempt is this". The lock gate
            // record is reused across attempts, so counting prior submissions against
            // it gives the real attempt number.
            Integer priorAttemptCount = [
                SELECT COUNT()
                FROM User_Submission__c
                WHERE Assignment_Eligibility__c = :lockGate.Id
            ];
            Decimal attemptNumber = priorAttemptCount + 1;

            Decimal totalMaxScore = 0;
            AggregateResult[] groupedResults = [
                SELECT SUM(Max_Points__c) totalPoints
                FROM Assignment_Question__c
                WHERE Assignment__c = :assignmentId
            ];
            if (!groupedResults.isEmpty() && groupedResults[0].get('totalPoints') != null) {
                totalMaxScore = (Decimal) groupedResults[0].get('totalPoints');
            }

            String submissionName = lockGate.Assignment__r.Name
                + ' - ' + lockGate.Contact__r.Name
                + ' - Attempt ' + attemptNumber
                + ' - ' + Date.today().format();

            User_Submission__c submission = new User_Submission__c();
            submission.Name = submissionName.length() > 80 ? submissionName.substring(0, 80) : submissionName;
            submission.Assignment_Eligibility__c = lockGate.Id;
            submission.Attempt_Number__c = attemptNumber;
            submission.Max_Score__c = totalMaxScore;
            submission.Status__c = 'Submitted';
            submission.Is_Locked__c = isLocked;

            if (isLocked) {
                submission.Lock_Reason__c = lockReason;
                submission.Violation_Count__c = violationCount;
            }
            insert as user submission;

            Map<Id, String> questionTextById = new Map<Id, String>();
            for (Assignment_Question__c q : [
                SELECT Id, Question_Text__c
                FROM Assignment_Question__c
                WHERE Id IN :answersMap.keySet()
            ]) {
                String shortText = q.Question_Text__c == null ? 'Question'
                    : (q.Question_Text__c.length() > 40 ? q.Question_Text__c.substring(0, 40) + '...' : q.Question_Text__c);
                questionTextById.put(q.Id, shortText);
            }

            List<Question_Response__c> responsesToInsert = new List<Question_Response__c>();
            for (Id questionId : answersMap.keySet()) {
                String answerText = answersMap.get(questionId);
                if (String.isBlank(answerText)) {
                    continue;
                }

                String respName = questionTextById.containsKey(questionId)
                    ? questionTextById.get(questionId) + ' - ' + lockGate.Contact__r.Name
                    : 'Response - ' + lockGate.Contact__r.Name;

                Question_Response__c resp = new Question_Response__c();
                resp.Name = respName.length() > 80 ? respName.substring(0, 80) : respName;
                resp.User_Submission__c = submission.Id;
                resp.Assignment_Question__c = questionId;
                resp.User_Answer__c = answerText;
                responsesToInsert.add(resp);
            }

            if (!responsesToInsert.isEmpty()) {
                insert as user responsesToInsert;
            }

            lockGate.Eligibility_Status__c = 'Completed';
            update as user lockGate;

            Assessment_Portal_Config__mdt AutoCreateAssignmentEligibility = [
                SELECT Auto_Create_Assignment_Eligibility__c
                FROM Assessment_Portal_Config__mdt
                LIMIT 1
            ];

            if (contactId != null && lockGate.Assignment__r.Sequence__c != null && AutoCreateAssignmentEligibility.Auto_Create_Assignment_Eligibility__c == true) {
                Decimal nextSequence = lockGate.Assignment__r.Sequence__c + 1;
                Id categoryId = lockGate.Assignment__r.Category__c;

                List<Assignment__c> nextAssignments = [
                    SELECT Id, Name FROM Assignment__c
                    WHERE Category__c = :categoryId
                    AND Sequence__c = :nextSequence
                    LIMIT 1
                ];

                if (!nextAssignments.isEmpty()) {
                    Id nextAsmId = nextAssignments[0].Id;
                    String nextAsmName = nextAssignments[0].Name;

                    List<Assignment_Eligibility__c> existingElig = [
                        SELECT Id FROM Assignment_Eligibility__c
                        WHERE Contact__c = :contactId
                        AND Assignment__c = :nextAsmId
                        LIMIT 1
                    ];

                    if (existingElig.isEmpty()) {
                        String eligName = nextAsmName + ' ' + lockGate.Contact__r.Name;

                        Assignment_Eligibility__c nextElig = new Assignment_Eligibility__c();
                        nextElig.Name = eligName.length() > 80 ? eligName.substring(0, 80) : eligName;
                        nextElig.Contact__c = contactId;
                        nextElig.Assignment__c = nextAsmId;
                        nextElig.Eligibility_Status__c = 'Eligible';
                        nextElig.Current_Attempt_Number__c = 1;
                        insert as user nextElig;
                    }
                }
            }

            return submission.Id;

        } catch (Exception e) {
            ErrorLogger.log(e);
            AuraHandledException AuraExc = new AuraHandledException('Transaction failed: ' + e.getMessage());
            AuraExc.setMessage('Transaction failed: ' + e.getMessage());
            throw AuraExc;
        }
    }

    /**
     * Returns the list of past attempts for a given assignment, for the running
     * user. Used to populate the attempt picker when a Completed assignment is
     * clicked. One row per User_Submission__c against the (single, reused)
     * Assignment_Eligibility__c record for this contact + assignment.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getSubmissionAttempts(Id assignmentId) {
        List<Map<String, Object>> attempts = new List<Map<String, Object>>();

        Id userId = UserInfo.getUserId();
        User currentUser = [SELECT ContactId FROM User WHERE Id = :userId LIMIT 1];
        Id contactId = currentUser.ContactId;
        if (contactId == null) {
            return attempts;
        }

        List<Assignment_Eligibility__c> eligList = [
            SELECT Id FROM Assignment_Eligibility__c
            WHERE Contact__c = :contactId AND Assignment__c = :assignmentId
            LIMIT 1
        ];
        if (eligList.isEmpty()) {
            return attempts;
        }
        Id eligibilityId = eligList[0].Id;

        List<User_Submission__c> submissions = [
            SELECT Id, Attempt_Number__c, CreatedDate, Max_Score__c,Pass_Fail_Status__c,Status__c,Score_Received__c,
            Is_Locked__c, Lock_Reason__c, Violation_Count__c
            FROM User_Submission__c
            WHERE Assignment_Eligibility__c = :eligibilityId
            ORDER BY Attempt_Number__c DESC
        ];

        Map<Id, Decimal> earnedBySubmission = new Map<Id, Decimal>();
        if (!submissions.isEmpty()) {
            Set<Id> submissionIds = new Map<Id, User_Submission__c>(submissions).keySet();
            AggregateResult[] grades = [
                SELECT User_Submission__c subId, SUM(AI_Grade__c) earned
                FROM Question_Response__c
                WHERE User_Submission__c IN :submissionIds
                GROUP BY User_Submission__c
            ];
            for (AggregateResult ar : grades) {
                earnedBySubmission.put((Id) ar.get('subId'), (Decimal) ar.get('earned'));
            }
        }

        for (User_Submission__c sub : submissions) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('Id', sub.Id);
            m.put('Attempt_Number__c', sub.Attempt_Number__c);
            m.put('CreatedDate', sub.CreatedDate);
            m.put('Score_Received__c', sub.Score_Received__c);
            m.put('Max_Score__c', sub.Max_Score__c);
            m.put('Earned_Score__c', earnedBySubmission.containsKey(sub.Id) ? earnedBySubmission.get(sub.Id) : 0);
            m.put('Pass_Fail_Status__c', sub.Pass_Fail_Status__c);
            m.put('Status__c', sub.Status__c);
            m.put('Is_Locked__c', sub.Is_Locked__c);
            m.put('Lock_Reason__c', sub.Lock_Reason__c);
            m.put('Violation_Count__c', sub.Violation_Count__c);
            attempts.add(m);
        }
        return attempts;
    }

    /**
     * Returns, for a single attempt: question text, the user's answer, and the
     * AI-assigned grade per question. Used by the read-only review screen.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getSubmissionDetail(Id submissionId) {
        List<Question_Response__c> responses = [
            SELECT Id, User_Answer__c, AI_Grade__c,
                   Assignment_Question__r.Question_Text__c,
                   Assignment_Question__r.Max_Points__c
            FROM Question_Response__c
            WHERE User_Submission__c = :submissionId
            ORDER BY Assignment_Question__r.CreatedDate ASC
        ];

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Question_Response__c r : responses) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('Id', r.Id);
            m.put('Question_Text__c', r.Assignment_Question__r.Question_Text__c);
            m.put('User_Answer__c', r.User_Answer__c);
            m.put('AI_Grade__c', r.AI_Grade__c);
            m.put('Max_Points__c', r.Assignment_Question__r.Max_Points__c);
            result.add(m);
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static Assessment_Portal_Config__mdt getPaginationSettings() {
        try {
            return [
                SELECT Assignment_Page_Size__c, Question_Page_Size__c 
                FROM Assessment_Portal_Config__mdt
                LIMIT 1
            ];
        } catch (Exception e) {
            ErrorLogger.log(e);
            AuraHandledException AuraExc = new AuraHandledException('Error retrieving pagination settings: ' + e.getMessage());
            AuraExc.setMessage('Error retrieving pagination settings: ' + e.getMessage());
            throw AuraExc;
        }
    }

    @AuraEnabled
    public static Map<String, Object> submitAssessmentFeedback(Id submissionId, String commentText) {
        Map<String, Object> result = new Map<String, Object>();
        try {
            if (submissionId == null) {
                AuraHandledException AuraExc = new AuraHandledException('Submission Id is required');
                AuraExc.setMessage('Submission Id is required');
                throw AuraExc;
            }
            if (String.isBlank(commentText)) {
                AuraHandledException AuraExc = new AuraHandledException('Feedback comment is required');
                AuraExc.setMessage('Feedback comment is required');
                throw AuraExc;
            }

            Id contactId = getCurrentContactIdForFeedback();
            Id queueId = getFeedbackQueueId();

            List<User_Submission__c> subList = [
                SELECT Name, Assignment_Eligibility__r.Assignment__r.Name 
                FROM User_Submission__c 
                WHERE Id = :submissionId 
                LIMIT 1
            ];
            String asmName = (!subList.isEmpty() && subList[0].Assignment_Eligibility__r.Assignment__r.Name != null)
                ? subList[0].Assignment_Eligibility__r.Assignment__r.Name
                : 'Assessment';

            String recordUrl = getExperienceSiteDetailUrl(submissionId);

            String fullDescription = 'Related Record: ' + asmName + '\n' +
                                    'Record Link: ' + recordUrl + '\n\n' +
                                    'Feedback:\n' + commentText;

            Case c = new Case(
                Subject     = 'Assessment Feedback: ' + asmName,
                Description = fullDescription,
                Status      = 'New',
                Type        = 'Assessment Feedback'
            );
            if (contactId != null) c.ContactId = contactId;
            if (queueId != null) c.OwnerId = queueId;

            Database.SaveResult sr = Database.insert(c, false, AccessLevel.SYSTEM_MODE);
            if (!sr.isSuccess()) {
                AuraHandledException AuraExc = new AuraHandledException('Unable to submit feedback: ' + sr.getErrors()[0].getMessage());
                AuraExc.setMessage('Unable to submit feedback: ' + sr.getErrors()[0].getMessage());
                throw AuraExc;
            }

            Id newCaseId = sr.getId();
            if (queueId != null) {
                sendQueueNotification(queueId, newCaseId, commentText, 'New Assessment Feedback');
            }

            result.put('success', true);
            result.put('caseId', newCaseId);
            result.put('taskId', newCaseId);
        } catch (Exception e) {
            ErrorLogger.log(e);
            AuraHandledException AuraExc = new AuraHandledException('Error submitting feedback: ' + e.getMessage());
            AuraExc.setMessage('Error submitting feedback: ' + e.getMessage());
            throw AuraExc;
        }
        return result;
    }

    @AuraEnabled
    public static Map<String, Object> submitQuestionFeedback(Id assignmentQuestionId, String commentText) {
        Map<String, Object> result = new Map<String, Object>();
        try {
            if (assignmentQuestionId == null) {
                AuraHandledException AuraExc = new AuraHandledException('Question Id is required');
                AuraExc.setMessage('Question Id is required');
                throw AuraExc;
            }
            if (String.isBlank(commentText)) {
                AuraHandledException AuraExc = new AuraHandledException('Feedback comment is required');
                AuraExc.setMessage('Feedback comment is required');
                throw AuraExc;
            }

            Id contactId = getCurrentContactIdForFeedback();
            Id queueId = getFeedbackQueueId();

            List<Assignment_Question__c> qList = [
                SELECT Question_Text__c, Assignment__r.Name 
                FROM Assignment_Question__c 
                WHERE Id = :assignmentQuestionId 
                LIMIT 1
            ];
            String asmName = (!qList.isEmpty() && qList[0].Assignment__r.Name != null) 
                ? qList[0].Assignment__r.Name 
                : 'Assignment';
            String qText = (!qList.isEmpty() && qList[0].Question_Text__c != null)
                ? qList[0].Question_Text__c
                : '';

            String recordUrl = getExperienceSiteDetailUrl(assignmentQuestionId);

            String fullDescription = 'Related Record: ' + asmName + '\n' +
                                    'Question: ' + qText + '\n' +
                                    'Record Link: ' + recordUrl + '\n\n' +
                                    'Feedback:\n' + commentText;

            Case c = new Case(
                Subject     = 'Question Feedback: ' + asmName,
                Description = fullDescription,
                Status      = 'New',
                Type        = 'Question Feedback'
            );
            if (contactId != null) c.ContactId = contactId;
            if (queueId != null) c.OwnerId = queueId;

            Database.SaveResult sr = Database.insert(c, false, AccessLevel.SYSTEM_MODE);
            if (!sr.isSuccess()) {
                AuraHandledException AuraExc = new AuraHandledException('Unable to submit feedback: ' + sr.getErrors()[0].getMessage());
                AuraExc.setMessage('Unable to submit feedback: ' + sr.getErrors()[0].getMessage());
                throw AuraExc;
            }

            Id newCaseId = sr.getId();
            if (queueId != null) {
                sendQueueNotification(queueId, newCaseId, commentText, 'New Question Feedback');
            }

            result.put('success', true);
            result.put('caseId', newCaseId);
            result.put('taskId', newCaseId);
        } catch (Exception e) {
            ErrorLogger.log(e);
            AuraHandledException AuraExc = new AuraHandledException('Error submitting feedback: ' + e.getMessage());
            AuraExc.setMessage('Error submitting feedback: ' + e.getMessage());
            throw AuraExc;
        }
        return result;
    }

    // If AssignmentService already has a helper that resolves ContactId, reuse
    // that instead of adding this duplicate.
    private static Id getCurrentContactIdForFeedback() {
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
    private static Id getFeedbackQueueId() {
        List<Group> queues = Database.query(
            'SELECT Id FROM Group WHERE Type = \'Queue\' AND DeveloperName = :QUEUE_DEV_NAME LIMIT 1',
            AccessLevel.SYSTEM_MODE
        );
        return queues.isEmpty() ? null : queues[0].Id;
    }
    private static void sendQueueNotification(Id queueId, Id taskId, String commentText, String title) {
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
            notification.setTitle(title);
            notification.setBody(bodyPreview);
            notification.setNotificationTypeId(notifTypes[0].Id);
            notification.setTargetId(taskId);

            notification.send(recipientIds);

        } catch (Exception e) {
            ErrorLogger.log(e);
            System.debug(LoggingLevel.ERROR, 'Notification send failed: ' + e.getMessage());
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