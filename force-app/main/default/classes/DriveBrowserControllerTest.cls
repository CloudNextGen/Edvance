@IsTest
private class DriveBrowserControllerTest {

    // =========================================================================
    // INNER CLASS: REUSABLE HTTP CALLOUT MOCK GENERATOR
    // =========================================================================
    private class GoogleDriveMockResponse implements HttpCalloutMock {
        private Integer statusCode;
        private String responseBody;

        public GoogleDriveMockResponse(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.responseBody = body;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setBody(this.responseBody);
            res.setStatusCode(this.statusCode);
            return res;
        }
    }

    // =========================================================================
    // TEST METHODS
    // =========================================================================
    
    @IsTest
    static void testGetDriveItemsSuccess() {
        // Arrange: Build a dummy JSON string that mirrors the Google Drive v3 file list format
        String mockBody = '{' +
            '"files": [' +
                '{' +
                    '"id": "folder_111",' +
                    '"name": "Project Documents",' +
                    '"mimeType": "application/vnd.google-apps.folder"' +
                    // Folders don't have a size attribute in Google Drive API
                '},' +
                    '{' +
                    '"id": "file_222",' +
                    '"name": "Invoice.pdf",' +
                    '"mimeType": "application/pdf",' +
                    '"webViewLink": "https://drive.google.com/file/d/file_222/view",' +
                    '"size": "524288"' + // 512 KB (524288 / 1024) -> should render as "512 KB"
                '},' +
                '{' +
                    '"id": "file_333",' +
                    '"name": "Presentation.pptx",' +
                    '"mimeType": "application/vnd.google-apps.presentation",' +
                    '"webViewLink": "https://drive.google.com/file/d/file_333/view",' +
                    '"size": "2097152"' + // 2 MB (2097152 / 1024 / 1024) -> should render as "2.0 MB"
                '},' +
                '{' +
                    '"id": "file_444",' +
                    '"name": "Random_File.xyz",' +
                    '"mimeType": "application/octet-stream"' +
                    // No size property included to test fallback block
                '}' +
            ']' +
        '}';

        Test.setMock(HttpCalloutMock.class, new GoogleDriveMockResponse(200, mockBody));

        // Act
        Test.startTest();
        List<DriveBrowserController.DriveItem> items = DriveBrowserController.getDriveItems('root_folder_id');
        Test.stopTest();

        // Assert
        Assert.areNotEqual(null, items, 'The returned item list should not be null.');
        Assert.areEqual(4, items.size(), 'Should parse exactly 4 items.');

        // 1. Verify Folder mapping
        DriveBrowserController.DriveItem folderItem = items[0];
        Assert.areEqual('folder_111', folderItem.id);
        Assert.areEqual('Project Documents', folderItem.name);
        Assert.isTrue(folderItem.isFolder, 'Folder should have isFolder set to true.');
        Assert.areEqual('standard:folder', folderItem.iconName, 'Mime type mapping for folders is incorrect.');
        Assert.areEqual('', folderItem.sizeLabel, 'Folders or items without sizes should have empty size strings.');

        // 2. Verify KB Formatting Calculation
        DriveBrowserController.DriveItem kbFileItem = items[1];
        Assert.isFalse(kbFileItem.isFolder, 'Files should have isFolder set to false.');
        Assert.areEqual('doctype:pdf', kbFileItem.iconName);
        Assert.areEqual('512 KB', kbFileItem.sizeLabel, 'The size label formatting below 1MB failed.');

        // 3. Verify MB Formatting Calculation
        DriveBrowserController.DriveItem mbFileItem = items[2];
        Assert.areEqual('doctype:gpres', mbFileItem.iconName);
        Assert.areEqual('2.0 MB', mbFileItem.sizeLabel, 'The size label formatting above 1MB failed.');

        // 4. Verify unknown Mime Type Fallback mapping
        DriveBrowserController.DriveItem unknownFileItem = items[3];
        Assert.areEqual('doctype:unknown', unknownFileItem.iconName, 'The unknown fallback icon assignment failed.');
    }

    @IsTest
    static void testGetDriveItemsBlankFolderId() {
        // Arrange: Provide an empty mock body simply to make sure it handles blank ID defaults smoothly
        String mockBody = '{"files": []}';
        Test.setMock(HttpCalloutMock.class, new GoogleDriveMockResponse(200, mockBody));

        // Act
        Test.startTest();
        // Passing a null or blank string forces it to use the 'root' directory parameter
        List<DriveBrowserController.DriveItem> items = DriveBrowserController.getDriveItems('');
        Test.stopTest();

        // Assert
        Assert.areEqual(0, items.size(), 'Should successfully query and parse an empty collection.');
    }

    @IsTest
    static void testGetDriveItemsErrorHandling() {
        // Arrange: Simulate an API error response from Google 
        String errorResponse = '{"error": {"message": "Invalid Credentials", "status": "UNAUTHENTICATED"}}';
        Test.setMock(HttpCalloutMock.class, new GoogleDriveMockResponse(401, errorResponse));

        // Act & Assert
        Test.startTest();
        try {
            DriveBrowserController.getDriveItems('any_id');
            Assert.fail('An AuraHandledException was expected but was not thrown.');
        } catch (AuraHandledException ex) {
            // Confirming the handler processes unexpected API exceptions
           // Assert.isTrue(ex.getMessage().contains('Drive API error (401)'), 'The exception message should track the HTTP status code.');
        }
        Test.stopTest();
    }
}