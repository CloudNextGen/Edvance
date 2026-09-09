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
}