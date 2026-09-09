@IsTest
private class LearningAccessAdminControllerTest {

    @TestSetup
    static void setupData() {
        // Create an Account required for Contact creation
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        // Create a Test Contact
        Contact con = new Contact(
            FirstName = 'Jane',
            LastName = 'Doe',
            AccountId = acc.Id
        );
        insert con;

        // Create a parent folder for files
        Learning_Folder__c folder = new Learning_Folder__c(Name = 'Core Training');
        insert folder;

        // Create multiple Learning Files
        List<Learning_File__c> files = new List<Learning_File__c>{
            new Learning_File__c(Name = 'Apex Basics', Learning_Folder__c = folder.Id),
            new Learning_File__c(Name = 'Lightning Web Components', Learning_Folder__c = folder.Id),
            new Learning_File__c(Name = 'Security Best Practices', Learning_Folder__c = folder.Id)
        };
        insert files;

        // Create an initial existing Learning Access record (Revoked status) to test the update logic
        Learning_Access__c existingAccess = new Learning_Access__c(
            Name = 'Security Best Practices - Jane Doe',
            Contact__c = con.Id,
            Learning_File__c = files[2].Id,
            Access_Status__c = 'Revoked'
        );
        insert existingAccess;
    }

    @IsTest
    static void testGetAssignableFiles_WithSearchTerm() {
        Contact con = [SELECT Id FROM Contact LIMIT 1];

        Test.startTest();
        List<LearningAccessAdminController.FileOption> results = 
            LearningAccessAdminController.getAssignableFiles(con.Id, 'Apex');
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'Should return exactly 1 file matching the search term.');
        Assert.areEqual('Apex Basics', results[0].fileName);
        Assert.isFalse(results[0].alreadyGranted, 'The access should not be marked as granted yet.');
    }

    @IsTest
    static void testGetAssignableFiles_AllNullSearchTerm() {
        Contact con = [SELECT Id FROM Contact LIMIT 1];

        Test.startTest();
        List<LearningAccessAdminController.FileOption> results = 
            LearningAccessAdminController.getAssignableFiles(con.Id, null);
        Test.stopTest();

        // Should return all 3 files since null treats search term as '%%'
        Assert.areEqual(3, results.size(), 'Should return all 3 files when search term is null.');
    }

    @IsTest
    static void testAssignFiles_InsertAndUpdateFlows() {
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        
        // Fetch files: 1 is completely brand new, 1 is currently 'Revoked'
        List<Learning_File__c> files = [SELECT Id FROM Learning_File__c WHERE Name IN ('Apex Basics', 'Security Best Practices')];
        List<Id> fileIds = new List<Id>();
        for(Learning_File__c f : files) {
            fileIds.add(f.Id);
        }

        Test.startTest();
        LearningAccessAdminController.assignFilesToContact(con.Id, fileIds);
        Test.stopTest();

        // Verify total records assigned to this contact
        List<Learning_Access__c> records = [
            SELECT Id, Name, Learning_File__r.Name, Access_Status__c, Granted_Date__c, Revoked_Date__c 
            FROM Learning_Access__c 
            WHERE Contact__c = :con.Id
        ];


        for (Learning_Access__c record : records) {
            if (record.Learning_File__r.Name == 'Apex Basics') {
                Assert.areEqual('Granted', record.Access_Status__c, 'Newly inserted record should be Granted.');
                Assert.isNotNull(record.Granted_Date__c);
            } else if (record.Learning_File__r.Name == 'Security Best Practices') {
                Assert.areEqual('Granted', record.Access_Status__c, 'Revoked record should update to Granted.');
                Assert.isNull(record.Revoked_Date__c, 'Revoked Date should be cleared out.');
            }
        }
    }

    @IsTest
    static void testAssignFiles_EmptyListException() {
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        List<Id> emptyList = new List<Id>();

        Test.startTest();
        try {
            LearningAccessAdminController.assignFilesToContact(con.Id, emptyList);
            Assert.fail('An AuraHandledException should have been thrown for an empty file list.');
        } catch (AuraHandledException e) {
           // Assert.isTrue(e.getMessage().contains('No files selected.'), 'Exception message should match.');
        }
        Test.stopTest();
    }

}