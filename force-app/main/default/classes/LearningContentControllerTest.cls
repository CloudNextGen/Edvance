@isTest
private class LearningContentControllerTest {

    private static final List<String> LICENSE_NAME_CANDIDATES = new List<String>{
        'Customer Community', 'Customer Community Plus', 'Customer Community Login',
        'Partner Community', 'PowerCustomerSuccess', 'PowerPartner'
    };

    private static String uniqueSuffix() {
        return UserInfo.getOrganizationId();
    }

    private static String adminUsername() {
        return 'lcc.admin.' + uniqueSuffix() + '@lcctest.invalid';
    }

    private static String portalUsername() {
        return 'lcc.portal.' + uniqueSuffix() + '@lcctest.invalid';
    }

    @TestSetup
    static void setupData() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            UserRole role = new UserRole(Name = 'LCC Test Role - ' + uniqueSuffix());
            insert role;

            Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
            User adminUser = new User(
                FirstName = 'LCC', LastName = 'Admin',
                Alias = 'lccadm', Email = adminUsername(),
                Username = adminUsername(),
                ProfileId = adminProfile.Id,
                UserRoleId = role.Id,
                TimeZoneSidKey = 'America/Los_Angeles', LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
            );
            insert adminUser;

            List<PermissionSet> adminPermSets = [
                SELECT Id FROM PermissionSet WHERE Name = 'Smart_Assessments_Portal_User' LIMIT 1
            ];
            if (!adminPermSets.isEmpty()) {
                insert new PermissionSetAssignment(
                    AssigneeId = adminUser.Id,
                    PermissionSetId = adminPermSets[0].Id
                );
            }
        }
        User adminUser = getAdminUser();
        Learning_Folder__c rootA = new Learning_Folder__c(Name = 'Root A', Sort_Order__c = 1);
        Learning_Folder__c rootB = new Learning_Folder__c(Name = 'Root B', Sort_Order__c = 2);
        Learning_Folder__c rootC = new Learning_Folder__c(Name = 'Root C', Sort_Order__c = 3);
        insert new List<Learning_Folder__c>{ rootA, rootB, rootC };

        Learning_File__c fileA1 = new Learning_File__c(
            Name = 'A1 - Intro', Learning_Folder__c = rootA.Id, Sort_Order__c = 1, Estimated_Time__c = 5
        );
        Learning_File__c fileA2 = new Learning_File__c(
            Name = 'A2 - Deep Dive', Learning_Folder__c = rootA.Id, Sort_Order__c = 2, Estimated_Time__c = 10
        );
        Learning_File__c fileB1 = new Learning_File__c(
            Name = 'B1 - Overview', Learning_Folder__c = rootB.Id, Sort_Order__c = 1
        );
        insert new List<Learning_File__c>{ fileA1, fileA2, fileB1 };

        Account acct = new Account(Name = 'LCC Test Account', OwnerId = adminUser.Id);
        insert acct;

        Contact con = new Contact(FirstName = 'LCC', LastName = 'Learner', AccountId = acct.Id);
        insert con;
        
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile portalProfile = getCommunityProfile();
            if (portalProfile != null) {
                User portalUser = new User(
                    FirstName = 'LCC', LastName = 'Learner',
                    Alias = 'lccusr', Email = portalUsername(),
                    Username = portalUsername(),
                    ProfileId = portalProfile.Id,
                    ContactId = con.Id,
                    TimeZoneSidKey = 'America/Los_Angeles', LocaleSidKey = 'en_US',
                    EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
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

            // Custom Notification Type is metadata and is not created here.
            Group queue = new Group(Name = 'Learning File Review Queue',Type = 'Queue');
            insert queue;

            try {
                insert new QueueSobject(QueueId = queue.Id, SobjectType = 'Task');
            } catch (Exception e) {
            }

            insert new GroupMember(GroupId = queue.Id, UserOrGroupId = adminUser.Id);
        }
    }

    private static Profile getCommunityProfile() {
        List<Profile> profiles = [
            SELECT Id, Name FROM Profile
            WHERE UserLicense.Name IN :LICENSE_NAME_CANDIDATES
            LIMIT 1
        ];
        return profiles.isEmpty() ? null : profiles[0];
    }

    private static User getAdminUser() {
        return [SELECT Id FROM User WHERE Username = :adminUsername() LIMIT 1];
    }

    private static User getPortalUserOrNull() {
        List<User> users = [SELECT Id, ContactId FROM User WHERE Username = :portalUsername() LIMIT 1];
        return users.isEmpty() ? null : users[0];
    }

    private static Contact getLearnerContact() {
        return [SELECT Id FROM Contact WHERE LastName = 'Learner' AND FirstName = 'LCC' LIMIT 1];
    }

    private static Learning_File__c getFileByName(String name) {
        return [SELECT Id, Name, Learning_Folder__c FROM Learning_File__c WHERE Name = :name LIMIT 1];
    }

    private static Learning_Folder__c getFolderByName(String name) {
        return [SELECT Id, Name FROM Learning_Folder__c WHERE Name = :name LIMIT 1];
    }

    @isTest
    static void testGetLearningContentTree_AdminSeesEverything() {
        User admin = getAdminUser();

        List<LearningContentController.FolderNode> tree;
        System.runAs(admin) {
            Test.startTest();
            tree = LearningContentController.getLearningContentTree();
            Test.stopTest();
        }

        System.assertEquals(3, tree.size(), 'Admin should see all three root folders (A, B, C)');

        Map<String, LearningContentController.FolderNode> byName = new Map<String, LearningContentController.FolderNode>();
        for (LearningContentController.FolderNode n : tree) {
            byName.put(n.name, n);
        }
        System.assert(byName.containsKey('Root A'));
        System.assert(byName.containsKey('Root B'));
        System.assert(byName.containsKey('Root C'));
        System.assertEquals(2, byName.get('Root A').files.size(), 'Root A should list both files for an admin');
        System.assertEquals(2, byName.get('Root A').totalFilesCount);
        System.assertEquals(2, byName.get('Root A').visibleFilesCount);
        System.assertEquals(0, byName.get('Root C').files.size(), 'Root C has no files');
    }

    @isTest
    static void testGetLearningContentTree_LearnerSeesOnlyGrantedFiles() {
        User portalUser = getPortalUserOrNull();
        if (portalUser == null) {
            System.debug('Skipping: no community/portal profile available in this org — see class header.');
            return;
        }

        Contact con = getLearnerContact();
        Learning_File__c fileA1 = getFileByName('A1 - Intro');
        Learning_File__c fileA2 = getFileByName('A2 - Deep Dive');

        insert new Learning_Access__c(
            Contact__c = con.Id, Learning_File__c = fileA1.Id,
            Access_Status__c = 'Granted', Completion_Status__c = 'Not Started', Name = 'A1 - Learner'
        );
        insert new Learning_Access__c(
            Contact__c = con.Id, Learning_File__c = fileA2.Id,
            Access_Status__c = 'Revoked', Completion_Status__c = 'Not Started', Name = 'A2 - Learner'
        );

        List<LearningContentController.FolderNode> tree;
        System.runAs(portalUser) {
            Test.startTest();
            tree = LearningContentController.getLearningContentTree();
            Test.stopTest();
        }

        LearningContentController.FolderNode rootA;
        for (LearningContentController.FolderNode n : tree) {
            if (n.name == 'Root A') {
                rootA = n;
            }
        }
        System.assertNotEquals(null, rootA, 'Root A should be reachable since the learner has access under it');
        System.assertEquals(1, rootA.visibleFilesCount, 'Only the granted file should count as visible');
        System.assertEquals(2, rootA.files.size(), 'Both granted and revoked files are returned (revoked flagged)');

        Boolean sawRevokedFlag = false;
        for (LearningContentController.FileNode f : rootA.files) {
            if (f.name == 'A2 - Deep Dive') {
                System.assertEquals(true, f.accessRevoked);
                sawRevokedFlag = true;
            } else if (f.name == 'A1 - Intro') {
                System.assertEquals(false, f.accessRevoked);
            }
        }
        System.assert(sawRevokedFlag, 'Revoked file should still be returned, flagged as revoked');

        // Root B was never touched by this learner and should not appear.
        for (LearningContentController.FolderNode n : tree) {
            System.assertNotEquals('Root B', n.name, 'Folders with no access at all should not be visible');
        }
    }

    @isTest
    static void testMarkFileComplete_UnlocksNextFileInSameFolder() {
        User portalUser = getPortalUserOrNull();
        if (portalUser == null) {
            System.debug('Skipping: no community/portal profile available in this org.');
            return;
        }

        Contact con = getLearnerContact();
        Learning_File__c fileA1 = getFileByName('A1 - Intro');
        insert new Learning_Access__c(
            Contact__c = con.Id, Learning_File__c = fileA1.Id,
            Access_Status__c = 'Granted', Completion_Status__c = 'Not Started', Name = 'A1 - Learner'
        );

        Map<String, Object> result;
        System.runAs(portalUser) {
            Test.startTest();
            result = LearningContentController.markFileComplete(fileA1.Id);
            Test.stopTest();
        }

        System.assertEquals(true, result.get('success'));
        System.assertEquals(false, result.get('nextFolderUnlocked'));

        Learning_File__c fileA2 = getFileByName('A2 - Deep Dive');
        System.assertEquals(fileA2.Id, (Id) result.get('nextFileId'));

        Learning_Access__c a1Access = [SELECT Completion_Status__c FROM Learning_Access__c WHERE Learning_File__c = :fileA1.Id AND Contact__c = :con.Id];
        System.assertEquals('Completed', a1Access.Completion_Status__c);

        List<Learning_Access__c> a2Access = [SELECT Access_Status__c FROM Learning_Access__c WHERE Learning_File__c = :fileA2.Id AND Contact__c = :con.Id];
        System.assertEquals(1, a2Access.size(), 'Next file in the folder should now have an access record');
        System.assertEquals('Granted', a2Access[0].Access_Status__c);
    }

    @isTest
    static void testMarkFileComplete_LastFileInFolderUnlocksNextFolder() {
        User portalUser = getPortalUserOrNull();
        if (portalUser == null) {
            System.debug('Skipping: no community/portal profile available in this org.');
            return;
        }

        Contact con = getLearnerContact();
        Learning_File__c fileA1 = getFileByName('A1 - Intro');
        Learning_File__c fileA2 = getFileByName('A2 - Deep Dive');

        insert new Learning_Access__c(
            Contact__c = con.Id, Learning_File__c = fileA1.Id,
            Access_Status__c = 'Granted', Completion_Status__c = 'Completed', Name = 'A1 - Learner'
        );
        insert new Learning_Access__c(
            Contact__c = con.Id, Learning_File__c = fileA2.Id,
            Access_Status__c = 'Granted', Completion_Status__c = 'Not Started', Name = 'A2 - Learner'
        );

        Map<String, Object> result;
        System.runAs(portalUser) {
            Test.startTest();
            result = LearningContentController.markFileComplete(fileA2.Id);
            Test.stopTest();
        }

        System.assertEquals(true, result.get('success'));
        System.assertEquals(true, result.get('nextFolderUnlocked'), 'Both files in Root A are complete, so Root B should unlock');

        Learning_File__c fileB1 = getFileByName('B1 - Overview');
        List<Learning_Access__c> b1Access = [SELECT Access_Status__c, Completion_Status__c FROM Learning_Access__c WHERE Learning_File__c = :fileB1.Id AND Contact__c = :con.Id];
        System.assertEquals(1, b1Access.size(), 'First file of the next content folder should be granted');
        System.assertEquals('Granted', b1Access[0].Access_Status__c);
        System.assertEquals('Not Started', b1Access[0].Completion_Status__c);
    }

    @isTest
    static void testMarkFileComplete_LastFolderInTreeHasNoNext() {
        User portalUser = getPortalUserOrNull();
        if (portalUser == null) {
            System.debug('Skipping: no community/portal profile available in this org.');
            return;
        }

        Contact con = getLearnerContact();
        Learning_File__c fileB1 = getFileByName('B1 - Overview');
        insert new Learning_Access__c(
            Contact__c = con.Id, Learning_File__c = fileB1.Id,
            Access_Status__c = 'Granted', Completion_Status__c = 'Not Started', Name = 'B1 - Learner'
        );

        Map<String, Object> result;
        System.runAs(portalUser) {
            Test.startTest();
            result = LearningContentController.markFileComplete(fileB1.Id);
            Test.stopTest();
        }

        System.assertEquals(true, result.get('success'));
        System.assertEquals(false, result.get('nextFolderUnlocked'));
        System.assertEquals(null, result.get('nextFileId'), 'Root B is the last content folder in pre-order, nothing left to unlock');
    }

    @isTest
    static void testMarkFileComplete_BlankFileIdThrows() {
        User portalUser = getPortalUserOrNull();
        if (portalUser == null) {
            System.debug('Skipping: no community/portal profile available in this org.');
            return;
        }

        Boolean threw = false;
        System.runAs(portalUser) {
            try {
                LearningContentController.markFileComplete('');
            } catch (AuraHandledException ex) {
                threw = true;
            }
        }
        System.assert(threw, 'Blank file Id should raise an AuraHandledException');
    }

    @isTest
    static void testMarkFileComplete_UnknownFileIdThrows() {
        User portalUser = getPortalUserOrNull();
        if (portalUser == null) {
            System.debug('Skipping: no community/portal profile available in this org.');
            return;
        }

        // A syntactically valid but non-existent Learning_File__c Id.
        Id fakeId = getFileByName('A1 - Intro').Id;
        delete [SELECT Id FROM Learning_File__c WHERE Id = :fakeId];

        Boolean threw = false;
        System.runAs(portalUser) {
            try {
                LearningContentController.markFileComplete(fakeId);
            } catch (AuraHandledException ex) {
                threw = true;
            }
        }
        System.assert(threw, 'A file Id that does not resolve to a record should raise an AuraHandledException');
    }

    @isTest
    static void testMarkFileComplete_NoContactThrows() {
        // Admin users typically have no associated Contact.
        User admin = getAdminUser();
        Learning_File__c fileA1 = getFileByName('A1 - Intro');

        Boolean threw = false;
        System.runAs(admin) {
            try {
                LearningContentController.markFileComplete(fileA1.Id);
            } catch (AuraHandledException ex) {
                threw = true;
            }
        }
        System.assert(threw, 'A user with no Contact should not be able to mark a file complete');
    }

    @isTest
    static void testRepairStalledUnlocks_GrantsMissingNextFolderAccess() {
        Contact con = getLearnerContact();
        Learning_File__c fileA1 = getFileByName('A1 - Intro');
        Learning_File__c fileA2 = getFileByName('A2 - Deep Dive');

        insert new Learning_Access__c(
            Contact__c = con.Id, Learning_File__c = fileA1.Id,
            Access_Status__c = 'Granted', Completion_Status__c = 'Completed', Name = 'A1 - Learner'
        );
        insert new Learning_Access__c(
            Contact__c = con.Id, Learning_File__c = fileA2.Id,
            Access_Status__c = 'Granted', Completion_Status__c = 'Completed', Name = 'A2 - Learner'
        );

        Map<String, Object> result;
        System.runAs(getAdminUser()) {
            Test.startTest();
            result = LearningContentController.repairStalledUnlocks();
            Test.stopTest();
        }

        System.assertEquals(true, result.get('success'));
        System.assertEquals(1, result.get('foldersUnlocked'));

        Learning_File__c fileB1 = getFileByName('B1 - Overview');
        List<Learning_Access__c> b1Access = [SELECT Access_Status__c FROM Learning_Access__c WHERE Learning_File__c = :fileB1.Id AND Contact__c = :con.Id];
        System.assertEquals(1, b1Access.size());
        System.assertEquals('Granted', b1Access[0].Access_Status__c);
    }

    @isTest
    static void testRepairStalledUnlocks_NoOpWhenNothingStalled() {
        Contact con = getLearnerContact();
        Learning_File__c fileA1 = getFileByName('A1 - Intro');

        insert new Learning_Access__c(
            Contact__c = con.Id, Learning_File__c = fileA1.Id,
            Access_Status__c = 'Granted', Completion_Status__c = 'Not Started', Name = 'A1 - Learner'
        );

        Map<String, Object> result;
        System.runAs(getAdminUser()) {
            Test.startTest();
            result = LearningContentController.repairStalledUnlocks();
            Test.stopTest();
        }

        System.assertEquals(true, result.get('success'));
        System.assertEquals(0, result.get('foldersUnlocked'), 'Folder A is not fully complete, nothing should be repaired');
    }

    @isTest
    static void testDebugNextContentFolder_ReturnsNextFolderAndFile() {
        Learning_Folder__c rootA = getFolderByName('Root A');
        Learning_Folder__c rootB = getFolderByName('Root B');
        Learning_File__c fileB1 = getFileByName('B1 - Overview');

        Map<String, Object> result;
        System.runAs(getAdminUser()) {
            Test.startTest();
            result = LearningContentController.debugNextContentFolder(rootA.Id);
            Test.stopTest();
        }

        System.assertEquals(String.valueOf(rootB.Id), (String) result.get('nextFolderId'));
        System.assertEquals(String.valueOf(fileB1.Id), (String) result.get('nextFileId'));
        System.assertEquals(fileB1.Name, (String) result.get('nextFileName'));
    }

   @isTest
    static void testDebugNextContentFolder_LastFolderReturnsNulls() {
        Learning_Folder__c rootB = getFolderByName('Root B');

        Map<String, Object> result;
        System.runAs(getAdminUser()) {
            Test.startTest();
            result = LearningContentController.debugNextContentFolder(rootB.Id);
            Test.stopTest();
        }

        System.assertEquals(null, result.get('nextFolderId'));
        System.assertEquals(null, result.get('nextFileId'));
    }

    @isTest
    static void testRecordFileOpened_CreatesAccessAndStampsTimestamp() {
        User portalUser = getPortalUserOrNull();
        if (portalUser == null) {
            System.debug('Skipping: no community/portal profile available in this org.');
            return;
        }

        Learning_File__c fileA1 = getFileByName('A1 - Intro');

        Map<String, Object> result;
        System.runAs(portalUser) {
            Test.startTest();
            result = LearningContentController.recordFileOpened(fileA1.Id);
            Test.stopTest();
        }

        System.assertEquals(true, result.get('success'));
        System.assertNotEquals(null, result.get('dateTimeOpened'));

        Contact con = getLearnerContact();
        Learning_Access__c access = [SELECT Date_Time_Opened__c, Access_Status__c FROM Learning_Access__c WHERE Learning_File__c = :fileA1.Id AND Contact__c = :con.Id];
        System.assertNotEquals(null, access.Date_Time_Opened__c);
        System.assertEquals('Granted', access.Access_Status__c);
    }

    @isTest
    static void testRecordFileOpened_DoesNotOverwriteExistingTimestamp() {
        User portalUser = getPortalUserOrNull();
        if (portalUser == null) {
            System.debug('Skipping: no community/portal profile available in this org.');
            return;
        }

        Contact con = getLearnerContact();
        Learning_File__c fileA1 = getFileByName('A1 - Intro');
        DateTime originalOpenedTime = DateTime.now().addDays(-1);

        insert new Learning_Access__c(
            Contact__c = con.Id, Learning_File__c = fileA1.Id,
            Access_Status__c = 'Granted', Completion_Status__c = 'Not Started',
            Date_Time_Opened__c = originalOpenedTime, Name = 'A1 - Learner'
        );

        Map<String, Object> result;
        System.runAs(portalUser) {
            Test.startTest();
            result = LearningContentController.recordFileOpened(fileA1.Id);
            Test.stopTest();
        }

        System.assertEquals(true, result.get('success'));
        System.assertEquals('File already opened', result.get('message'));
        System.assertEquals(originalOpenedTime, result.get('dateTimeOpened'));
    }

    @isTest
    static void testRecordFileOpened_AdminHasNothingToTrack() {
        Learning_File__c fileA1 = getFileByName('A1 - Intro');

        Map<String, Object> result;
        System.runAs(getAdminUser()) {
            Test.startTest();
            result = LearningContentController.recordFileOpened(fileA1.Id);
            Test.stopTest();
        }

        System.assertEquals(true, result.get('success'));
        System.assertEquals('Admin access - no tracking required', result.get('message'));
    }

    @isTest
    static void testRecordFileOpened_BlankFileIdThrows() {
        Boolean threw = false;
        System.runAs(getAdminUser()) {
            try {
                LearningContentController.recordFileOpened(null);
            } catch (AuraHandledException ex) {
                threw = true;
            }
        }
        System.assert(threw);
    }

    @isTest
    static void testSubmitFileFeedback_CreatesTask() {
        Learning_File__c fileA1 = getFileByName('A1 - Intro');

        Map<String, Object> result;
        System.runAs(getAdminUser()) {
            Test.startTest();
            result = LearningContentController.submitFileFeedback(fileA1.Id, 'This section was very helpful, thanks!');
            Test.stopTest();
        }

        System.assertEquals(true, result.get('success'));
        Id taskId = (Id) result.get('taskId');
        System.assertNotEquals(null, taskId);

        Task t = [SELECT Subject, Description, Status, WhatId FROM Task WHERE Id = :taskId];
        System.assertEquals('Learning Content Feedback', t.Subject);
        System.assertEquals('This section was very helpful, thanks!', t.Description);
        System.assertEquals('Completed', t.Status);
        System.assertEquals(fileA1.Id, t.WhatId);
    }

    @isTest
    static void testSubmitFileFeedback_BlankCommentThrows() {
        Learning_File__c fileA1 = getFileByName('A1 - Intro');

        Boolean threw = false;
        System.runAs(getAdminUser()) {
            try {
                LearningContentController.submitFileFeedback(fileA1.Id, '   ');
            } catch (AuraHandledException ex) {
                threw = true;
            }
        }
        System.assert(threw, 'Blank feedback text should raise an AuraHandledException');
    }

    @isTest
    static void testSubmitFileFeedback_BlankFileIdThrows() {
        Boolean threw = false;
        System.runAs(getAdminUser()) {
            try {
                LearningContentController.submitFileFeedback(null, 'Some comment');
            } catch (AuraHandledException ex) {
                threw = true;
            }
        }
        System.assert(threw, 'Blank file Id should raise an AuraHandledException');
    }
}