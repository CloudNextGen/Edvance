public without sharing class AdminDashboardController {
    
    @AuraEnabled(cacheable=true)
    public static List<Contact> getExperienceUsers() {
        Id currentUserId = UserInfo.getUserId();

        return [
            SELECT Id, Name, Email, Phone, Title, Account.Name,
                   (SELECT Id FROM Assignment_Eligibilities__r)
            FROM Contact 
            WHERE Id IN (
                SELECT ContactId 
                FROM User 
                WHERE IsActive = true 
                AND Id != :currentUserId
                AND ContactId != null
            )
            ORDER BY Name ASC
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Category__c> getCategories() {
        return [SELECT Id, Name FROM Category__c ORDER BY Name ASC];
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getAdminAssignmentsForCategory(Id categoryId, Id contactId) {
        List<Assignment__c> allAssignments = [
            SELECT Id, Name, Total_Question_Count__c
            FROM Assignment__c
            WHERE Category__c = :categoryId 
            ORDER BY Sequence__c ASC NULLS LAST
        ];

        Map<Id, String> statusByAssignmentId = new Map<Id, String>();
        if (contactId != null) {
            for (Assignment_Eligibility__c eligibility : [
                SELECT Assignment__c, Eligibility_Status__c
                FROM Assignment_Eligibility__c
                WHERE Contact__c = :contactId
                AND Assignment__r.Category__c = :categoryId
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

            String rawStatus = 'Locked';
            if (statusByAssignmentId.containsKey(asm.Id)) {
                rawStatus = statusByAssignmentId.get(asm.Id);
            }
            
            asmMap.put('status', rawStatus);
            asmMap.put('isEligibleStatus', rawStatus == 'Eligible');
            asmMap.put('isCompletedStatus', rawStatus == 'Completed');
            asmMap.put('isLockedStatus', rawStatus == 'Locked');
            assignmentsWithStatus.add(asmMap);
        }
        return assignmentsWithStatus;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getAdminSubmissionAttempts(Id assignmentId, Id contactId) {
        List<Map<String, Object>> attempts = new List<Map<String, Object>>();
        if (contactId == null) return attempts;

        List<Assignment_Eligibility__c> eligList = [
            SELECT Id FROM Assignment_Eligibility__c
            WHERE Contact__c = :contactId AND Assignment__c = :assignmentId
            LIMIT 1
        ];
        if (eligList.isEmpty()) return attempts;
        Id eligibilityId = eligList[0].Id;

        List<User_Submission__c> submissions = [
            SELECT Id, Attempt_Number__c, CreatedDate, Max_Score__c,
                   Pass_Fail_Status__c, Status__c, Is_Locked__c, Lock_Reason__c, Violation_Count__c
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

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getAdminSubmissionDetail(Id submissionId) {
        List<Question_Response__c> responses = [
            SELECT Id, User_Answer__c, AI_Grade__c,
                   Assignment_Question__r.Question_Text__c,
                   Assignment_Question__r.Max_Points__c,AI_Feedback__c
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
            m.put('AI_Feedback__c', r.AI_Feedback__c);
            result.add(m);
        }
        return result;
    }
}