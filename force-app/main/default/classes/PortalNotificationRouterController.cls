public with sharing class PortalNotificationRouterController {
    @AuraEnabled(cacheable=true)
    public static String getNotificationRecordType(Id recordId) {
        if (recordId == null) {
            return null;
        }

        String recordType = recordId.getSObjectType().getDescribe().getName();
        return recordType == 'Attendance_Log__c' || recordType == 'Case' ? recordType : null;
    }
}