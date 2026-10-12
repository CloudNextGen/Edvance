@IsTest
private class AdminDashboardControllerTest {

    @TestSetup
    static void setupData() {
        // 1. Fetch a UserRole — mandatory for the owner of an account hosting portal users
        UserRole dummyRole = [SELECT Id FROM UserRole WHERE PortalType = 'None' LIMIT 1];
        
        User thisUser = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        thisUser.UserRoleId = dummyRole.Id;
        update thisUser;
        
        System.runAs(thisUser) {
            // Create an Account owned by a user with a role
            Account acc = new Account(Name = 'Test Partner Account');
            insert acc;

            // Create a Contact
            Contact con = new Contact(
                FirstName = 'Alex',
                LastName = 'Explorer',
                Email = 'alex.explorer@test.com',
                Title = 'Software Engineer',
                AccountId = acc.Id
            );
            insert con;

            // 2. Bulletproof Portal Profile Selection: Query by actual External License Type
            Profile portalProfile;
            List<Profile> profiles = [
                SELECT Id 
                FROM Profile 
                WHERE UserLicense.LicenseDefinitionKey IN ('PID_Customer_Community', 'PID_Customer_Community_Login', 'PID_Partner_Community')
                LIMIT 1
            ];
            
            if (!profiles.isEmpty()) {
                portalProfile = profiles[0];
            } else {
                // Absolute fallback if no digital experiences are enabled in the environment
                portalProfile = [SELECT Id FROM Profile WHERE Name = 'Customer Community User' LIMIT 1];
            }

            // Create a matching active Community/Experience User tied to the Contact
            User experienceUser = new User(
                Alias = 'alexp',
                Email = 'alex.explorer@test.com',
                EmailEncodingKey = 'UTF-8',
                LastName = 'Explorer',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = portalProfile.Id,
                TimeZoneSidKey = 'America/Los_Angeles',
                UserName = 'alex.explorer.uniquetest@test.com',
                ContactId = con.Id,
                IsActive = true
            );
            insert experienceUser;

            // Create Dashboard Metadata Structure
            Category__c cat = new Category__c(Name = 'Cloud Architecture');
            insert cat;

            Assignment__c asm = new Assignment__c(
                Name = 'Apex Design Patterns',
                Category__c = cat.Id,
                Sequence__c = 1
            );
            insert asm;

            Assignment_Question__c q1 = new Assignment_Question__c(
                Assignment__c = asm.Id,
                Question_Text__c = 'Explain bulkification.',
                Max_Points__c = 10
            );
            insert q1;

            // Create Eligibility
            Assignment_Eligibility__c elig = new Assignment_Eligibility__c(
                Contact__c = con.Id,
                Assignment__c = asm.Id,
                Eligibility_Status__c = 'Eligible'
            );
            insert elig;

            // Create Submission History
            User_Submission__c sub = new User_Submission__c(
                Assignment_Eligibility__c = elig.Id,
                Attempt_Number__c = 1,
                Max_Score__c = 20,
                Status__c = 'Draft,',
                Is_Locked__c = false,
                Violation_Count__c = 0
            );
            insert sub;

            // Create Responses tied to grades
            Question_Response__c resp = new Question_Response__c(
                User_Submission__c = sub.Id,
                Assignment_Question__c = q1.Id,
                User_Answer__c = 'Using maps to group sets of records.',
                AI_Grade__c = 9.5,
                AI_Feedback__c = 'Excellent understanding.'
            );
            insert resp;
        }
    }

    @IsTest
    static void testGetExperienceUsers() {
        Test.startTest();
        List<Contact> contacts = AdminDashboardController.getExperienceUsers();
        Test.stopTest();

        Assert.areEqual(1, contacts.size(), 'Should find exactly 1 Contact linked to an active user.');
        Assert.areEqual('Alex Explorer', contacts[0].Name);
    }

    @IsTest
    static void testGetCategories() {
        Test.startTest();
        List<Category__c> cats = AdminDashboardController.getCategories();
        Test.stopTest();

        Assert.areEqual(1, cats.size(), 'Should return our setup category.');
        Assert.areEqual('Cloud Architecture', cats[0].Name);
    }

    @IsTest
    static void testGetAdminAssignmentsForCategory() {
        Category__c cat = [SELECT Id FROM Category__c LIMIT 1];
        Contact con = [SELECT Id FROM Contact LIMIT 1];

        Test.startTest();
        List<Map<String, Object>> assignments = AdminDashboardController.getAdminAssignmentsForCategory(cat.Id, con.Id);
        List<Map<String, Object>> assignmentsNullContact = AdminDashboardController.getAdminAssignmentsForCategory(cat.Id, null);
        Test.stopTest();

        Assert.areEqual(1, assignments.size());
        Assert.areEqual('Apex Design Patterns', assignments[0].get('Name'));
        Assert.areEqual('Eligible', assignments[0].get('status'));
        Assert.isTrue((Boolean) assignments[0].get('isEligibleStatus'));
        Assert.isFalse((Boolean) assignments[0].get('isLockedStatus'));

        Assert.areEqual(1, assignmentsNullContact.size());
        Assert.areEqual('Locked', assignmentsNullContact[0].get('status'));
        Assert.isTrue((Boolean) assignmentsNullContact[0].get('isLockedStatus'));
    }

    @IsTest
    static void testGetAdminSubmissionAttempts() {
        Assignment__c asm = [SELECT Id FROM Assignment__c LIMIT 1];
        Contact con = [SELECT Id FROM Contact LIMIT 1];

        Test.startTest();
        List<Map<String, Object>> attempts = AdminDashboardController.getAdminSubmissionAttempts(asm.Id, con.Id);
        List<Map<String, Object>> emptyAttemptsNullContact = AdminDashboardController.getAdminSubmissionAttempts(asm.Id, null);
        Test.stopTest();

        Assert.areEqual(1, attempts.size(), 'Should extract 1 submission trace.');
        Assert.areEqual(1.0, (Decimal) attempts[0].get('Attempt_Number__c'));
        Assert.areEqual(9.5, (Decimal) attempts[0].get('Earned_Score__c'));
        Assert.areEqual(null, attempts[0].get('Pass_Fail_Status__c'));
        Assert.areEqual(0, emptyAttemptsNullContact.size());
    }

    @IsTest
    static void testGetAdminSubmissionDetail() {
        User_Submission__c sub = [SELECT Id FROM User_Submission__c LIMIT 1];

        Test.startTest();
        List<Map<String, Object>> details = AdminDashboardController.getAdminSubmissionDetail(sub.Id);
        Test.stopTest();

        Assert.areEqual(1, details.size());
        Assert.areEqual('Explain bulkification.', details[0].get('Question_Text__c'));
        Assert.areEqual(9.5, details[0].get('AI_Grade__c'));
        Assert.areEqual('Excellent understanding.', details[0].get('AI_Feedback__c'));
    }

    @IsTest
    static void testRevokeAndReassignAssignment() {
        LearningAccessAdminController.mentorAssignmentAllowedOverride = true;
        LearningAccessAdminController.systemAdministratorOverride = true;
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        Assignment_Eligibility__c eligibility = [
            SELECT Id, Assignment__c
            FROM Assignment_Eligibility__c
            WHERE Contact__c = :con.Id
            LIMIT 1
        ];

        Test.startTest();
        Assignmentadmincontroller.revokeAssignmentFromContact(con.Id, eligibility.Id);

        Assignment_Eligibility__c revoked = [
            SELECT Id, Eligibility_Status__c
            FROM Assignment_Eligibility__c
            WHERE Id = :eligibility.Id
        ];
        Assert.areEqual('Revoked', revoked.Eligibility_Status__c);

        List<Assignmentadmincontroller.CategoryNode> tree =
            Assignmentadmincontroller.getAssignableAssignmentsTree(con.Id, null);
        Assignmentadmincontroller.AssignmentOption revokedOption;
        for (Assignmentadmincontroller.CategoryNode category : tree) {
            for (Assignmentadmincontroller.AssignmentOption option : category.assignments) {
                if (option.assignmentId == eligibility.Assignment__c) {
                    revokedOption = option;
                }
            }
        }
        Assert.isNotNull(revokedOption);
        Assert.areEqual('Not Assigned', revokedOption.status);
        Assert.isFalse(revokedOption.canRevoke);

        Assignmentadmincontroller.assignAssignmentsToContact(con.Id, new List<Id>{ eligibility.Assignment__c });
        Test.stopTest();

        Assignment_Eligibility__c reassigned = [
            SELECT Id, Eligibility_Status__c
            FROM Assignment_Eligibility__c
            WHERE Contact__c = :con.Id AND Assignment__c = :eligibility.Assignment__c
        ];
        Assert.areEqual(eligibility.Id, reassigned.Id, 'Reassigning should reactivate the existing eligibility record.');
        Assert.areEqual('Eligible', reassigned.Eligibility_Status__c);
    }

    @IsTest
    static void testAssignmentTreeStatusesSearchAndOrdering() {
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        Category__c category = [SELECT Id, Name FROM Category__c LIMIT 1];
        Assignment__c existingAssignment = [SELECT Id FROM Assignment__c LIMIT 1];
        Assignment_Eligibility__c existingEligibility = [
            SELECT Id
            FROM Assignment_Eligibility__c
            WHERE Contact__c = :con.Id AND Assignment__c = :existingAssignment.Id
            LIMIT 1
        ];
        existingEligibility.Eligibility_Status__c = 'Completed';
        update existingEligibility;

        Assignment__c secondAssignment = new Assignment__c(
            Name = 'Advanced Architecture',
            Category__c = category.Id,
            Sequence__c = 2
        );
        Category__c secondCategory = new Category__c(Name = 'Category 2');
        insert secondCategory;
        Assignment__c thirdAssignment = new Assignment__c(
            Name = 'Category 2 Assignment',
            Category__c = secondCategory.Id,
            Sequence__c = 1
        );
        Category__c thirdCategory = new Category__c(Name = 'Cloud Beta');
        insert thirdCategory;
        Assignment__c fourthAssignment = new Assignment__c(
            Name = 'Cloud Beta Assignment',
            Category__c = thirdCategory.Id,
            Sequence__c = 1
        );
        insert new List<Assignment__c>{ secondAssignment, thirdAssignment, fourthAssignment };
        insert new Assignment_Eligibility__c(
            Contact__c = con.Id,
            Assignment__c = secondAssignment.Id,
            Eligibility_Status__c = 'Locked'
        );

        Test.startTest();
        List<Assignmentadmincontroller.CategoryNode> tree =
            Assignmentadmincontroller.getAssignableAssignmentsTree(con.Id, null);
        List<Assignmentadmincontroller.CategoryNode> filteredTree =
            Assignmentadmincontroller.getAssignableAssignmentsTree(con.Id, 'Category 2');
        Test.stopTest();

        Assert.areEqual(3, tree.size());
        Assignmentadmincontroller.CategoryNode originalCategory;
        Assignmentadmincontroller.CategoryNode numberedCategory;
        Assignmentadmincontroller.CategoryNode otherCloudCategory;
        for (Assignmentadmincontroller.CategoryNode node : tree) {
            if (node.categoryName == category.Name) originalCategory = node;
            if (node.categoryName == 'Category 2') numberedCategory = node;
            if (node.categoryName == 'Cloud Beta') otherCloudCategory = node;
        }
        Assert.isNotNull(originalCategory);
        Assert.isNotNull(numberedCategory);
        Assert.isNotNull(otherCloudCategory);
        Assert.areEqual(2, originalCategory.assignments.size());
        Assert.areEqual('Completed', originalCategory.assignments[0].status);
        Assert.isTrue(originalCategory.assignments[0].canReassign);
        Assert.isTrue(originalCategory.assignments[0].canRevoke);
        Assert.areEqual('Locked', originalCategory.assignments[1].status);
        Assert.isTrue(originalCategory.assignments[1].canReassign);
        Assert.isTrue(originalCategory.assignments[1].canRevoke);
        Assert.areEqual('Not Assigned', numberedCategory.assignments[0].status);
        Assert.areEqual(1, filteredTree.size());
        Assert.areEqual('Category 2', filteredTree[0].categoryName);
        Assert.areEqual('Cloud Architecture', tree[1].categoryName);
        Assert.areEqual(10, Assignmentadmincontroller.extractNumber('Category 10'));
        Assert.areEqual(10, Assignmentadmincontroller.extractNumber('10 items'));
        Assert.areEqual(9999, Assignmentadmincontroller.extractNumber('No number'));
        Assert.areEqual(9999, Assignmentadmincontroller.extractNumber(null));
    }

    @IsTest
    static void testAssignmentValidationAndRevokeErrors() {
        LearningAccessAdminController.mentorAssignmentAllowedOverride = true;
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        Assignment_Eligibility__c eligibility = [
            SELECT Id
            FROM Assignment_Eligibility__c
            WHERE Contact__c = :con.Id
            LIMIT 1
        ];

        Boolean emptyAssignRejected = false;
        try {
            Assignmentadmincontroller.assignAssignmentsToContact(con.Id, new List<Id>());
        } catch (AuraHandledException error) {
            emptyAssignRejected = true;
        }
        Assert.isTrue(emptyAssignRejected);

        Boolean invalidRevokeRejected = false;
        try {
            Assignmentadmincontroller.revokeAssignmentFromContact(con.Id, null);
        } catch (AuraHandledException error) {
            invalidRevokeRejected = true;
        }
        Assert.isTrue(invalidRevokeRejected);

        Id unrelatedRecordId = [SELECT Id FROM User_Submission__c LIMIT 1].Id;
        Boolean wrongEligibilityRejected = false;
        try {
            Assignmentadmincontroller.revokeAssignmentFromContact(con.Id, unrelatedRecordId);
        } catch (AuraHandledException error) {
            wrongEligibilityRejected = true;
        }
        Assert.isTrue(wrongEligibilityRejected);

        Assignmentadmincontroller.revokeAssignmentFromContact(con.Id, eligibility.Id);
        Boolean repeatedRevokeRejected = false;
        try {
            Assignmentadmincontroller.revokeAssignmentFromContact(con.Id, eligibility.Id);
        } catch (AuraHandledException error) {
            repeatedRevokeRejected = true;
        }
        Assert.isTrue(repeatedRevokeRejected);
    }

    @IsTest
    static void testAssignNewAssignmentAndReassignCompletedAssignment() {
        LearningAccessAdminController.mentorAssignmentAllowedOverride = true;
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        Category__c category = [SELECT Id FROM Category__c LIMIT 1];
        Assignment__c existingAssignment = [SELECT Id FROM Assignment__c LIMIT 1];
        Assignment_Eligibility__c eligibility = [
            SELECT Id
            FROM Assignment_Eligibility__c
            WHERE Contact__c = :con.Id AND Assignment__c = :existingAssignment.Id
            LIMIT 1
        ];
        eligibility.Eligibility_Status__c = 'Completed';
        update eligibility;

        Assignment__c newAssignment = new Assignment__c(
            Name = 'New Admin Assignment',
            Category__c = category.Id,
            Sequence__c = 5
        );
        insert newAssignment;

        Test.startTest();
        Assignmentadmincontroller.reassignAssignment(eligibility.Id);
        Assignmentadmincontroller.assignAssignmentsToContact(con.Id, new List<Id>{ newAssignment.Id });
        Test.stopTest();

        Assert.areEqual(
            'Eligible',
            [SELECT Eligibility_Status__c FROM Assignment_Eligibility__c WHERE Id = :eligibility.Id].Eligibility_Status__c
        );
        Assert.areEqual(
            1,
            [SELECT count() FROM Assignment_Eligibility__c WHERE Contact__c = :con.Id AND Assignment__c = :newAssignment.Id]
        );
    }

    @IsTest
    static void testPortalUserStatusSearchAndActivation() {
        AdminDashboardController.managePortalUsersAccessOverride = true;
        User portalUser = [
            SELECT Id, IsActive
            FROM User
            WHERE Username = 'alex.explorer.uniquetest@test.com'
            LIMIT 1
        ];

        AdminDashboardController.UserStatusPage activePage =
            AdminDashboardController.getPortalUsersByStatus(true, 'Alex', 0);
        Assert.areEqual(1, activePage.users.size(), 'Search should find the active portal user.');
        Assert.areEqual(portalUser.Id, activePage.users[0].id);

        Test.startTest();
        AdminDashboardController.setPortalUserActive(portalUser.Id, false);
        Test.stopTest();

        User deactivatedUser = [SELECT IsActive FROM User WHERE Id = :portalUser.Id];
        Assert.isFalse(deactivatedUser.IsActive);
        AdminDashboardController.UserStatusPage inactivePage =
            AdminDashboardController.getPortalUsersByStatus(false, 'alex.explorer', 0);
        Assert.areEqual(1, inactivePage.users.size(), 'Deactivated portal users should be searchable.');
        Assert.areEqual(portalUser.Id, inactivePage.users[0].id);

        AdminDashboardController.setPortalUserActive(portalUser.Id, true);
        Assert.isTrue([SELECT IsActive FROM User WHERE Id = :portalUser.Id].IsActive);
    }

    @IsTest
    static void testPortalUserStatusRequiresHrOrAdmin() {
        AdminDashboardController.managePortalUsersAccessOverride = false;
        Boolean denied = false;
        try {
            AdminDashboardController.getPortalUsersByStatus(false, null, 0);
        } catch (AuraHandledException e) {
            denied = true;
        }
        Assert.isTrue(denied, 'Users without HR or System Administrator access must be denied.');
    }
}