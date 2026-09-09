public class OneDriveIntegrationService {

    // '@future(callout=true)' runs the code in the background so the user's screen doesn't freeze
    @future(callout=true)
    public static void createOneDriveFolder(String accountName, String accountId) {

        // Concatenation Logic: Combines Account Name and ID into: "AccountName (ID)"
        String folderName = accountName + ' (' + accountId + ')';

        Http http = new Http();
        HttpRequest request = new HttpRequest();

        // Points to Salesforce's Named Credential to access the root OneDrive folder
        request.setEndpoint('callout:OneDrive_Integration/v1.0/me/drive/root/children');
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');

        // Prepare the JSON Body for Microsoft Graph API
        Map<String, Object> requestBody = new Map<String, Object>();
        requestBody.put('name', folderName); // Sends our concatenated name
        requestBody.put('folder', new Map<String, Object>()); // Tells Microsoft to make a folder, not a file
        requestBody.put('@microsoft.graph.conflictBehavior', 'rename'); // If the folder exists, rename the new one

        request.setBody(JSON.serialize(requestBody));

        try {
            HttpResponse response = http.send(request);
            if (response.getStatusCode() == 201) {
                System.debug('Folder Successfully Created: ' + folderName);
            } else {
                System.debug('Error from Microsoft: ' + response.getStatusCode() + ' body: ' + response.getBody());
            }
        } catch (Exception e) {
            System.debug('Callout Exception: ' + e.getMessage());
        }
    }
}