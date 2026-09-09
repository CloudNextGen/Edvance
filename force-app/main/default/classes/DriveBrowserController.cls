public with sharing class DriveBrowserController {

    public class DriveItem {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String mimeType;
        @AuraEnabled public Boolean isFolder;
        @AuraEnabled public String webViewLink;
        @AuraEnabled public String iconName;
        @AuraEnabled public String sizeLabel;
    }

    @AuraEnabled
    public static List<DriveItem> getDriveItems(String folderId) {
        String parentId = String.isBlank(folderId) ? 'root' : folderId;
        String query = '\'' + parentId + '\' in parents and trashed = false';

        String fieldsParam = 'files(id,name,mimeType,webViewLink,size)';
        String endpoint = '/drive/v3/files?q=' + EncodingUtil.urlEncode(query, 'UTF-8')
            + '&fields=' + EncodingUtil.urlEncode(fieldsParam, 'UTF-8')
            + '&orderBy=' + EncodingUtil.urlEncode('folder,name', 'UTF-8')
            + '&pageSize=100';

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Google_Drive_API' + endpoint);
        req.setMethod('GET');
        req.setTimeout(20000);

        Http http = new Http();
        HttpResponse res = http.send(req);

        List<DriveItem> results = new List<DriveItem>();

        if (res.getStatusCode() == 200) {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> files = (List<Object>) body.get('files');

            for (Object fObj : files) {
                Map<String, Object> f = (Map<String, Object>) fObj;
                DriveItem item = new DriveItem();
                item.id = (String) f.get('id');
                item.name = (String) f.get('name');
                item.mimeType = (String) f.get('mimeType');
                item.webViewLink = (String) f.get('webViewLink');
                item.isFolder = item.mimeType == 'application/vnd.google-apps.folder';
                item.iconName = getIconForMimeType(item.mimeType);

                if (f.get('size') != null) {
                    Decimal kb = Decimal.valueOf((String) f.get('size')) / 1024;
                    item.sizeLabel = kb < 1024
                        ? kb.setScale(0) + ' KB'
                        : (kb / 1024).setScale(1) + ' MB';
                } else {
                    item.sizeLabel = '';
                }

                results.add(item);
            }
        } else {
            throw new AuraHandledException('Drive API error (' + res.getStatusCode() + '): ' + res.getBody());
        }

        return results;
    }

    private static String getIconForMimeType(String mimeType) {
        if (mimeType == 'application/vnd.google-apps.folder') return 'standard:folder';
        if (mimeType == 'application/pdf') return 'doctype:pdf';
        if (mimeType != null && mimeType.startsWith('video/')) return 'doctype:video';
        if (mimeType != null && mimeType.startsWith('image/')) return 'doctype:image';
        if (mimeType == 'application/vnd.google-apps.document') return 'doctype:gdoc';
        if (mimeType == 'application/vnd.google-apps.presentation') return 'doctype:gpres';
        if (mimeType == 'application/vnd.google-apps.spreadsheet') return 'doctype:gsheet';
        return 'doctype:unknown';
    }
}