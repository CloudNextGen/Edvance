public with sharing class PortalHomeController {
    @AuraEnabled(cacheable=true)
    public static Map<String, Map<String, String>> getProfileDetails() {
        Map<String, Map<String, String>> result = new Map<String, Map<String, String>>();

        try {
            Id userId = UserInfo.getUserId();
            List<User> users = [
                SELECT ContactId
                FROM User
                WHERE Id = :userId
                LIMIT 1
            ];

            if (users.isEmpty() || users[0].ContactId == null) {
                return result;
            }

            Contact currentContact = [
                SELECT
                    HR__c,
                    Manager__c,
                    HR__r.Name,
                    Manager__r.Name,
                    HR_Email__c,
                    Manager_Email__c
                FROM Contact
                WHERE Id = :users[0].ContactId
                WITH SYSTEM_MODE
                LIMIT 1
            ];

            if (currentContact.HR__c != null) {
                result.put(
                    'hr',
                    buildProfileRecord(currentContact.HR__r.Name, currentContact.HR_Email__c)
                );
            }

            if (currentContact.Manager__c != null) {
                result.put(
                    'manager',
                    buildProfileRecord(currentContact.Manager__r.Name, currentContact.Manager_Email__c)
                );
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'PortalHomeController.getProfileDetails failed: ' + e.getMessage());
        }

        return result;
    }

    private static Map<String, String> buildProfileRecord(String name, String email) {
        Map<String, String> profile = new Map<String, String>();

        profile.put('name', String.isBlank(name) ? '' : name);
        profile.put('email', String.isBlank(email) ? '' : email);
        profile.put('profile', buildInitials(name));

        return profile;
    }

    private static String buildInitials(String name) {
        if (String.isBlank(name)) {
            return 'M';
        }

        List<String> parts = name.trim().split(' ');
        String initials = '';

        for (Integer i = 0; i < Math.min(2, parts.size()); i++) {
            if (!String.isBlank(parts[i])) {
                initials += parts[i].substring(0, 1).toUpperCase();
            }
        }

        return String.isBlank(initials) ? 'M' : initials;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean isCommunityUser() {
        return UserInfo.getUserType() != 'Standard';
    }
}