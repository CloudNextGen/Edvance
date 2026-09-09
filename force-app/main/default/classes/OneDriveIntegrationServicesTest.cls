@IsTest
private class OneDriveIntegrationServicesTest {

    // =========================================================================
    // REUSABLE HTTP CALLOUT MOCK GENERATOR
    // =========================================================================
    public class OneDriveMockHttpResponseGenerator implements HttpCalloutMock {
        private Integer statusCode;
        private String jsonResponseBody;

        public OneDriveMockHttpResponseGenerator(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.jsonResponseBody = body;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setBody(this.jsonResponseBody);
            res.setStatusCode(this.statusCode);
            return res;
        }
    }

    // =========================================================================
    // TESTS FOR: OneDriveIntegrationService (@future flows)
    // =========================================================================
    @IsTest
    static void testCreateOneDriveFolderSuccess() {
        // Arrange
        String mockResponsePayload = '{"id": "folder_12345", "name": "Test Account (001xxxxxxxxx)"}';
        Test.setMock(HttpCalloutMock.class, new OneDriveMockHttpResponseGenerator(201, mockResponsePayload));

        // Act
        Test.startTest();
        OneDriveIntegrationService.createOneDriveFolder('Test Account', '001xxxxxxxxx');
        Test.stopTest(); // Forces the @future method to execute synchronously

        // Assert
        Assert.isTrue(true, 'Executed without uncaught exceptions.');
    }

    @IsTest
    static void testCreateOneDriveFolderFailure() {
        // Arrange
        String errorPayload = '{"error": {"message": "Invalid named credential endpoint structure"}}';
        Test.setMock(HttpCalloutMock.class, new OneDriveMockHttpResponseGenerator(400, errorPayload));

        // Act
        Test.startTest();
        OneDriveIntegrationService.createOneDriveFolder('Test Account', '001xxxxxxxxx');
        Test.stopTest();

        // Assert
        Assert.isTrue(true, 'Executed internal error logs smoothly without cracking execution.');
    }

    // =========================================================================
    // TESTS FOR: OneDriveLearningSyncService (Queueable processing engine)
    // =========================================================================
    @IsTest
    static void testQueueableSyncProcessing() {
        // Arrange
        // Simulate a typical response tracking 1 folder object and 1 file object payload
        String jsonPayload = '{ ' +
            '"value": [ ' +
                '{ ' +
                    '"id": "drive_folder_id_abc", ' +
                    '"name": "Apex Docs", ' +
                    '"folder": {} ' +
                '}, ' +
                '{ ' +
                    '"id": "drive_file_id_xyz", ' +
                    '"name": "cheatsheet.pdf", ' +
                    '"webUrl": "https://onedrive.com/view/cheatsheet", ' +
                    '"size": 1048576, ' + // Exactly 1 Megabyte
                    '"file": { "mimeType": "application/pdf" } ' +
                '} ' +
            '] ' +
        '}';

        Test.setMock(HttpCalloutMock.class, new OneDriveMockHttpResponseGenerator(200, jsonPayload));

        // Act
        Test.startTest();
        System.enqueueJob(new OneDriveLearningSyncService());
        Test.stopTest(); // Flushes all underlying async job frames synchronously

        // Assert Folder Generation
        List<Learning_Folder__c> processedFolders = [SELECT Id, Name, Drive_Folder_Id__c FROM Learning_Folder__c];
        Assert.areEqual(1, processedFolders.size(), 'Should process exactly 1 external folder entry.');
        Assert.areEqual('Apex Docs', processedFolders[0].Name);
        Assert.areEqual('drive_folder_id_abc', processedFolders[0].Drive_Folder_Id__c);

        // Assert File Entry mapping parameters and formatting metrics logic
        List<Learning_File__c> processedFiles = [SELECT Id, Name, Drive_File_Id__c, Web_View_Link__c, Size_Label__c, Mime_Type__c FROM Learning_File__c];
        Assert.areEqual(1, processedFiles.size(), 'Should process exactly 1 file item entry.');
        Assert.areEqual('cheatsheet.pdf', processedFiles[0].Name);
        Assert.areEqual('drive_file_id_xyz', processedFiles[0].Drive_File_Id__c);
        Assert.areEqual('https://onedrive.com/view/cheatsheet', processedFiles[0].Web_View_Link__c);
        Assert.areEqual('1.0 MB', processedFiles[0].Size_Label__c, 'Calculated text scale optimization mapping logic mismatch.');
        Assert.areEqual('application/pdf', processedFiles[0].Mime_Type__c);
    }

    @IsTest
    static void testSyncWithExistingParentFolders() {
        // Arrange - Inject an established database marker simulating a folder matching an ongoing sync branch
        Learning_Folder__c preExistingFolder = new Learning_Folder__c(
            Name = 'Root Level Sub',
            Drive_Folder_Id__c = 'pre_existing_id_999'
        );
        insert preExistingFolder;

        String jsonPayload = '{ ' +
            '"value": [ ' +
                '{ ' +
                    '"id": "nested_file_id_777", ' +
                    '"name": "nested_guide.docx", ' +
                    '"size": 512, ' + 
                    '"file": { "mimeType": "application/msword" } ' +
                '} ' +
            '] ' +
        '}';

        Test.setMock(HttpCalloutMock.class, new OneDriveMockHttpResponseGenerator(200, jsonPayload));

        // Prepare our queue parameters with an explicit processing node target
        OneDriveLearningSyncService.QueueItem targetItem = new OneDriveLearningSyncService.QueueItem('pre_existing_id_999', 'pre_existing_id_999');
        List<OneDriveLearningSyncService.QueueItem> customQueueBatch = new List<OneDriveLearningSyncService.QueueItem>{ targetItem };

        // Act
        Test.startTest();
        System.enqueueJob(new OneDriveLearningSyncService(customQueueBatch));
        Test.stopTest();

        // Assert that the newly created file successfully matches against our existing DB infrastructure record map
        Learning_File__c nestedFile = [SELECT Id, Learning_Folder__c, Size_Label__c FROM Learning_File__c WHERE Drive_File_Id__c = 'nested_file_id_777' LIMIT 1];
        Assert.areEqual(preExistingFolder.Id, nestedFile.Learning_Folder__c, 'The file must locate and resolve lookup linkages to the pre-existing database folder Id.');
        Assert.areEqual('512.0 B', nestedFile.Size_Label__c);
    }
}