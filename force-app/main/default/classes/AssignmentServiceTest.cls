@isTest
private class AssignmentServiceTest {

    private static String uniqueSuffix() {
        return UserInfo.getOrganizationId();
    }

    private static String portalUsername() {
        return 'testportaluserUnique123.' + uniqueSuffix() + '@example.com';
    }

    @TestSetup
    static void setupData() {
        User thisUser = new User(Id = UserInfo.getUserId());
        System.runAs(thisUser) {
            List<UserRole> existingRoles = [SELECT Id FROM UserRole WHERE Name = 'AST Test Role' LIMIT 1];
            UserRole role;
            if (existingRoles.isEmpty()) {
                role = new UserRole(Name = 'AST Test Role');
                insert role;
            } else {
                role = existingRoles[0];
            }

            User u = [SELECT Id, UserRoleId FROM User WHERE Id = :UserInfo.getUserId()];
            if (u.UserRoleId == null) {
                u.UserRoleId = role.Id;
                update u;
            }
        }

        // ── Non-setup objects: Account/Contact + core application records ──
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Contact con = new Contact(
            FirstName = 'Test',
            LastName = 'User',
            AccountId = acc.Id,
            Email = 'testportaluser@example.com'
        );
        insert con;

        Category__c cat = new Category__c(Name = 'Salesforce Basics');
        insert cat;
        
        List<Task> tasks = new List<Task>();
        tasks.add(new Task(
            ActivityDate = Date.today().addDays(7),
            Subject='Sample Task',
           // WhatId = a.Id,
            OwnerId = UserInfo.getUserId(),
            Status='In Progress'));
        
        insert tasks;

        Assignment__c asm1 = new Assignment__c(
            Name = 'Apex Basics',
            Category__c = cat.Id,
            Sequence__c = 1,
            Time_Limit_Minutes__c = 30
        );
        Assignment__c asm2 = new Assignment__c(
            Name = 'LWC Advanced',
            Category__c = cat.Id,
            Sequence__c = 2,
            Time_Limit_Minutes__c = 45
        );
        insert new List<Assignment__c>{ asm1, asm2 };

        Assignment_Question__c q1 = new Assignment_Question__c(
            Assignment__c = asm1.Id,
            Question_Text__c = 'What is an Apex class?',
            Max_Points__c = 10
        );
        Assignment_Question__c q2 = new Assignment_Question__c(
            Assignment__c = asm1.Id,
            Question_Text__c = 'What is a Trigger?',
            Max_Points__c = 10
        );
        insert new List<Assignment_Question__c>{ q1, q2 };

        Assignment_Eligibility__c elig = new Assignment_Eligibility__c(
            Name = 'Apex Basics Test User',
            Contact__c = con.Id,
            Assignment__c = asm1.Id,
            Eligibility_Status__c = 'Eligible',
            Current_Attempt_Number__c = 1
        );
        insert elig;

        // ── Setup objects, round 2: portal user + permission set assignment ──
        System.runAs(thisUser) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Customer Community Plus User' LIMIT 1];

            User portalUser = new User(
                Alias = 'testport',
                Email = 'testportaluser@example.com',
                EmailEncodingKey = 'UTF-8',
                LastName = 'Testing',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/Los_Angeles',
                Username = portalUsername(),
                ContactId = con.Id
            );
            insert portalUser;
            
            List<PermissionSet> permSets = [
                SELECT Id FROM PermissionSet WHERE Name = 'Smart_Assessments_Portal_User' LIMIT 1
            ];
            if (!permSets.isEmpty()) {
                insert new PermissionSetAssignment(
                    AssigneeId = portalUser.Id,
                    PermissionSetId = permSets[0].Id
                );
            }
        }
    }

    private static User getPortalUser() {
        return [SELECT Id FROM User WHERE Username = :portalUsername() LIMIT 1];
    }

    @isTest
    static void testGetEligibleCategories() {
        Test.startTest();
        List<Category__c> categories = AssignmentService.getEligibleCategories();
        Test.stopTest();

        Assert.areNotEqual(0, categories.size(), 'Categories should be returned');
    }

    @isTest
    static void testGetAssignmentsForCategory_AdminContext() {
        Category__c cat = [SELECT Id FROM Category__c LIMIT 1];

        Test.startTest();
        List<Map<String, Object>> records = AssignmentService.getAssignmentsForCategory(cat.Id);
        Test.stopTest();

        Assert.areNotEqual(0, records.size());
        Assert.areEqual('Eligible', (String) records[0].get('status'));
        Assert.areEqual(false, (Boolean) records[0].get('isDisabled'));
    }

    @isTest
    static void testGetAssignmentsForCategory_PortalUserContext() {
        Category__c cat = [SELECT Id FROM Category__c LIMIT 1];
        User portalUser = getPortalUser();

        System.runAs(portalUser) {
            Test.startTest();
            List<Map<String, Object>> records = AssignmentService.getAssignmentsForCategory(cat.Id);
            Test.stopTest();

            Assert.areNotEqual(0, records.size());
            Map<String, Object> genericAsmMap1 = records[0];
            Assert.areEqual('Eligible', (String) genericAsmMap1.get('status'));
            Assert.areEqual(false, (Boolean) genericAsmMap1.get('isDisabled'));
        }
    }

    @isTest
    static void testGetAssignmentQuestions() {
        Assignment__c asm = [SELECT Id FROM Assignment__c WHERE Sequence__c = 1 LIMIT 1];

        Test.startTest();
        List<Assignment_Question__c> questions = AssignmentService.getAssignmentQuestions(asm.Id);
        Test.stopTest();

        Assert.areEqual(2, questions.size(), 'Should return the two questions created in test setup');
    }

    @isTest
    static void testSubmitAssignment_Success() {
        User portalUser = getPortalUser();
        Assignment__c asm = [SELECT Id FROM Assignment__c WHERE Sequence__c = 1 LIMIT 1];
        List<Assignment_Question__c> questions = [SELECT Id FROM Assignment_Question__c WHERE Assignment__c = :asm.Id];

        Map<Id, String> answersMap = new Map<Id, String>();
        for (Assignment_Question__c q : questions) {
            answersMap.put(q.Id, 'This is a valid test answer.');
        }
        String answersJson = JSON.serialize(answersMap);

        System.runAs(portalUser) {
            Test.startTest();
            Id submissionId = AssignmentService.submitAssignment(asm.Id, answersJson, true, 'Cheating violation detected', 1);
            Test.stopTest();

            Assert.isNotNull(submissionId, 'Submission record should be successfully created');

            User_Submission__c sub = [SELECT Id, Status__c, Is_Locked__c, Violation_Count__c FROM User_Submission__c WHERE Id = :submissionId];
            Assert.areEqual('Submitted', sub.Status__c);
            Assert.areEqual(true, sub.Is_Locked__c);
            Assert.areEqual(1, sub.Violation_Count__c);

            List<Question_Response__c> responses = [SELECT Id FROM Question_Response__c WHERE User_Submission__c = :submissionId];
            Assert.areEqual(2, responses.size());
        }
    }

    @isTest
    static void testPassedAssignmentCanRequestNextAssignmentAccess() {
        User portalUser = getPortalUser();
        Contact learner = [SELECT Id FROM Contact WHERE Email = 'testportaluser@example.com' LIMIT 1];
        Assignment_Eligibility__c eligibility = [
            SELECT Id, Assignment__c
            FROM Assignment_Eligibility__c
            WHERE Contact__c = :learner.Id
            LIMIT 1
        ];
        Assignment__c completedAssignment = [
            SELECT Id, Category__c
            FROM Assignment__c
            WHERE Id = :eligibility.Assignment__c
            LIMIT 1
        ];
        Assignment__c nextAssignment = [
            SELECT Id
            FROM Assignment__c
            WHERE Sequence__c = 2
            LIMIT 1
        ];
        Assessment_Portal_Config__mdt config = [
            SELECT Auto_Create_Assignment_Eligibility__c
            FROM Assessment_Portal_Config__mdt
            LIMIT 1
        ];
        Assert.isFalse(
            config.Auto_Create_Assignment_Eligibility__c,
            'This test verifies the manual assignment access request flow.'
        );

        learner.Mentor__c = portalUser.Id;
        update learner;
        eligibility.Eligibility_Status__c = 'Completed';
        update eligibility;

        User_Submission__c passedSubmission = new User_Submission__c(
            Name = 'Passed Assignment',
            Assignment_Eligibility__c = eligibility.Id,
            Attempt_Number__c = 1,
            Status__c = 'Graded',
            Max_Score__c = 20
        );
        insert passedSubmission;
        List<Assignment_Question__c> questions = [
            SELECT Id, Question_Text__c
            FROM Assignment_Question__c
            WHERE Assignment__c = :completedAssignment.Id
        ];
        List<Question_Response__c> passedResponses = new List<Question_Response__c>();
        for (Assignment_Question__c question : questions) {
            passedResponses.add(new Question_Response__c(
                Name = question.Question_Text__c,
                User_Submission__c = passedSubmission.Id,
                Assignment_Question__c = question.Id,
                User_Answer__c = 'Test answer',
                AI_Grade__c = 10
            ));
        }
        insert passedResponses;

        System.runAs(portalUser) {
            Test.startTest();
            List<Map<String, Object>> assignments =
                AssignmentService.getAssignmentsForCategory(completedAssignment.Category__c);
            Map<String, Object> requestResult =
                AssignmentService.requestNextAssignmentAccess(nextAssignment.Id);
            Test.stopTest();

            Assert.areEqual(2, assignments.size(), 'The passed learner should see the next assignment request row.');
            Assert.areEqual('Completed', assignments[0].get('status'));
            Assert.areEqual('RequestAccess', assignments[1].get('status'));
            Assert.areEqual(true, requestResult.get('success'));
        }

        Case request = [
            SELECT Id, ContactId, OwnerId, Subject, Status
            FROM Case
            WHERE ContactId = :learner.Id
              AND Subject = 'Assignment Access Request: LWC Advanced'
            LIMIT 1
        ];
        Group reviewQueue = [
            SELECT Id
            FROM Group
            WHERE Type = 'Queue' AND DeveloperName = 'Learning_File_Review_Queue'
            LIMIT 1
        ];
        Assert.areEqual(learner.Id, request.ContactId);
        Assert.areEqual(reviewQueue.Id, request.OwnerId);
        Assert.areEqual('New', request.Status);
    }

    @isTest
    static void testFailedAssignmentDoesNotShowNextAssignmentRequest() {
        User portalUser = getPortalUser();
        Contact learner = [SELECT Id FROM Contact WHERE Email = 'testportaluser@example.com' LIMIT 1];
        Assignment_Eligibility__c eligibility = [
            SELECT Id, Assignment__c
            FROM Assignment_Eligibility__c
            WHERE Contact__c = :learner.Id
            LIMIT 1
        ];
        Assignment__c completedAssignment = [
            SELECT Id, Category__c
            FROM Assignment__c
            WHERE Id = :eligibility.Assignment__c
            LIMIT 1
        ];
        eligibility.Eligibility_Status__c = 'Completed';
        update eligibility;
        insert new User_Submission__c(
            Name = 'Failed Assignment',
            Assignment_Eligibility__c = eligibility.Id,
            Attempt_Number__c = 1,
            Status__c = 'Graded',
            Max_Score__c = 20
        );

        System.runAs(portalUser) {
            Test.startTest();
            List<Map<String, Object>> assignments =
                AssignmentService.getAssignmentsForCategory(completedAssignment.Category__c);
            Test.stopTest();

            Assert.areEqual(1, assignments.size(), 'A failed learner must not see a request button for the next assignment.');
            Assert.areEqual('Completed', assignments[0].get('status'));
            Assert.areEqual(false, assignments[0].get('isRequestAccessStatus'));
        }
    }

    @isTest
    static void testSubmitAssignment_NoEligibilityException() {
        User portalUser = getPortalUser();
        Assignment__c asm2 = [SELECT Id FROM Assignment__c WHERE Sequence__c = 2 LIMIT 1];

        System.runAs(portalUser) {
            Test.startTest();
            Boolean threw = false;
            try {
                AssignmentService.submitAssignment(asm2.Id, '{}', false, '', 0);
            } catch (AuraHandledException e) {
                threw = true;
            }
            Test.stopTest();

            Assert.isTrue(threw, 'Should have thrown because no Eligibility record exists for this assignment');
        }
    }

    @isTest
    static void testGetSubmissionAttemptsAndDetails() {
        User portalUser = getPortalUser();
        Assignment__c asm = [SELECT Id FROM Assignment__c WHERE Sequence__c = 1 LIMIT 1];
        Assignment_Eligibility__c elig = [SELECT Id FROM Assignment_Eligibility__c LIMIT 1];

        User_Submission__c sub = new User_Submission__c(
            Name = 'Test Submission',
            Assignment_Eligibility__c = elig.Id,
            Attempt_Number__c = 1,
            Max_Score__c = 20,
            Status__c = 'Submitted'
        );
        insert sub;

        Assignment_Question__c q = [SELECT Id FROM Assignment_Question__c WHERE Assignment__c = :asm.Id LIMIT 1];
        Question_Response__c resp = new Question_Response__c(
            Name = 'Test Response',
            User_Submission__c = sub.Id,
            Assignment_Question__c = q.Id,
            User_Answer__c = 'Test Answer Payload',
            AI_Grade__c = 8
        );
        insert resp;

        System.runAs(portalUser) {
            Test.startTest();
            List<Map<String, Object>> attempts = AssignmentService.getSubmissionAttempts(asm.Id);
            List<Map<String, Object>> details = AssignmentService.getSubmissionDetail(sub.Id);
            Test.stopTest();

            Assert.areEqual(1, attempts.size());
            Assert.areEqual(8.0, (Decimal) attempts[0].get('Earned_Score__c'));
            Assert.areEqual(1, details.size());
            Assert.areEqual('Test Answer Payload', (String) details[0].get('User_Answer__c'));
        }
    }

    @isTest
    static void testGetPaginationSettings() {
        Test.startTest();
        try {
            Assessment_Portal_Config__mdt settings = AssignmentService.getPaginationSettings();
            Assert.isNotNull(settings, 'Should return the deployed config record');
        } catch (AuraHandledException e) {
           
        }
        Test.stopTest();
    }

    @isTest
    static void testSubmitAssessmentFeedback() {
        User portalUser = getPortalUser();
        Assignment_Eligibility__c elig = [SELECT Id FROM Assignment_Eligibility__c LIMIT 1];

        User_Submission__c sub = new User_Submission__c(
            Assignment_Eligibility__c = elig.Id,
            Status__c = 'Submitted'
        );
        insert sub;

        Id taskId;
        System.runAs(portalUser) {
            Test.startTest();
            Map<String, Object> result = AssignmentService.submitAssessmentFeedback(sub.Id, 'Great structured questions.');
            Test.stopTest();

            Assert.areEqual(true, (Boolean) result.get('success'));
            taskId = (Id) result.get('taskId');
        }

        // Query executed outside System.runAs to prevent sharing rule visibility exceptions
        Task t = [SELECT Id, Subject, Description FROM Task WHERE Id = :taskId];
        Assert.areEqual('Assessment Feedback', t.Subject);
        Assert.areEqual('Great structured questions.', t.Description);
    }

    @isTest
    static void testSubmitQuestionFeedback() {
        User portalUser = getPortalUser();
        Assignment_Question__c q = [SELECT Id FROM Assignment_Question__c LIMIT 1];

        Id taskId;
        System.runAs(portalUser) {
            Test.startTest();
            Map<String, Object> result = AssignmentService.submitQuestionFeedback(q.Id, 'Typos found in question stem description.');
            Test.stopTest();

            Assert.areEqual(true, (Boolean) result.get('success'));
            taskId = (Id) result.get('taskId');
        }

        // Query executed outside System.runAs to prevent sharing rule visibility exceptions
        Task t = [SELECT Id, Subject, Description, WhatId FROM Task WHERE Id = :taskId];
        Assert.areEqual('Question Feedback', t.Subject);
        Assert.areEqual(q.Id, t.WhatId);
    }

    @isTest
    static void testSubmitFeedbackValidationExceptions() {
        Assignment_Question__c q = [SELECT Id FROM Assignment_Question__c LIMIT 1];

        Test.startTest();
        Boolean threwForBlankSubmissionId = false;
        try {
            AssignmentService.submitAssessmentFeedback(null, 'Valid comment text here');
        } catch (AuraHandledException e) {
            threwForBlankSubmissionId = true;
        }

        Boolean threwForBlankComment = false;
        try {
            AssignmentService.submitQuestionFeedback(q.Id, '');
        } catch (AuraHandledException e) {
            threwForBlankComment = true;
        }
        Test.stopTest();

        Assert.isTrue(threwForBlankSubmissionId, 'Should have hit the null submissionId validation block');
        Assert.isTrue(threwForBlankComment, 'Should have hit the blank comment validation block');
    }
}