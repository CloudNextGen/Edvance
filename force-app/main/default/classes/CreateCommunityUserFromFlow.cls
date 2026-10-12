public without sharing class CreateCommunityUserFromFlow {

    public class DefaultLookupUsers {
        @AuraEnabled public Id hrId { get; set; }
        @AuraEnabled public Id managerId { get; set; }
        @AuraEnabled public Id mentorId { get; set; }
        @AuraEnabled public String warningMessage { get; set; }
    }

    private static final Set<String> ALLOWED_USER_TYPES = new Set<String>{
        'HR',
        'Mentor',
        'Team Member'
    };

    @AuraEnabled
    public static DefaultLookupUsers getDefaultLookupUsers() {
        DefaultLookupUsers defaults = new DefaultLookupUsers();
        Attendance_Config__mdt config = Attendance_Config__mdt.getInstance('Office');

        if (config == null) {
            defaults.warningMessage =
                'Attendance Config metadata is missing. No lookup defaults were loaded.';
            return defaults;
        }

        Map<String, String> configuredEmailsByRole = new Map<String, String>{
            'HR' => config.HR_Email__c,
            'Manager' => config.Manager_Email__c,
            'Mentor' => config.Mentor_Email__c
        };
        Set<String> configuredEmails = new Set<String>();
        for (String configuredEmail : configuredEmailsByRole.values()) {
            if (!String.isBlank(configuredEmail)) {
                configuredEmails.add(configuredEmail.trim());
            }
        }

        if (configuredEmails.isEmpty()) {
            return defaults;
        }

        Map<String, Id> userIdsByEmail = new Map<String, Id>();
        for (User configuredUser : [
            SELECT Id, Email
            FROM User
            WHERE IsActive = true AND Email IN :configuredEmails
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC
        ]) {
            String emailKey = configuredUser.Email == null
                ? null
                : configuredUser.Email.trim().toLowerCase();
            if (emailKey != null && !userIdsByEmail.containsKey(emailKey)) {
                userIdsByEmail.put(emailKey, configuredUser.Id);
            }
        }

        List<String> unresolvedRoles = new List<String>();
        for (String role : configuredEmailsByRole.keySet()) {
            String configuredEmail = configuredEmailsByRole.get(role);
            if (String.isBlank(configuredEmail)) {
                continue;
            }

            Id configuredUserId = userIdsByEmail.get(configuredEmail.trim().toLowerCase());
            if (configuredUserId == null) {
                unresolvedRoles.add(role);
                continue;
            }

            if (role == 'HR') {
                defaults.hrId = configuredUserId;
            } else if (role == 'Manager') {
                defaults.managerId = configuredUserId;
            } else if (role == 'Mentor') {
                defaults.mentorId = configuredUserId;
            }
        }

        if (!unresolvedRoles.isEmpty()) {
            defaults.warningMessage =
                'No active user was found for the configured email on: ' +
                String.join(unresolvedRoles, ', ') +
                '. Check the email values in Attendance Config metadata.';
        }
        return defaults;
    }

    @AuraEnabled
    public static String createContactAndUser(
        String firstName,
        String lastName,
        String email,
        String phone,
        Id accountId,
        String userType,
        Id hrId,
        Id managerId,
        Id mentorId
    ) {
        try {
            if (String.isBlank(firstName) || String.isBlank(lastName) ||
                String.isBlank(email)     || accountId == null ||
                String.isBlank(userType)) {
                return 'Error: All required fields must be filled.';
            }

            if (!ALLOWED_USER_TYPES.contains(userType)) {
                return 'Error: User Type "' + userType + '" cannot be created from this form.';
            }

            Account parentAccount = [
                SELECT Id, OwnerId, Owner.UserType
                FROM Account
                WHERE Id = :accountId
                LIMIT 1
            ];

            Id contactOwnerId = parentAccount.OwnerId;

            if (parentAccount.Owner.UserType != 'Standard') {
                List<User> internalUsers = [
                    SELECT Id FROM User
                    WHERE UserType    = 'Standard'
                    AND IsActive      = true
                    AND UserRoleId   != null
                    ORDER BY CreatedDate ASC
                    LIMIT 1
                ];
                if (!internalUsers.isEmpty()) {
                    contactOwnerId = internalUsers[0].Id;
                }
            }

            // Create Contact and populate User lookup fields on Contact
            Contact con     = new Contact();
            con.FirstName   = firstName;
            con.LastName    = lastName;
            con.Email       = email;
            con.Phone       = phone;
            con.AccountId   = accountId;
            con.OwnerId     = contactOwnerId;
            con.HR__c       = hrId;
            con.Manager__c  = managerId;
            con.Mentor__c   = mentorId;
            insert con;

            // Handle duplicate username
            String username = email + '.edvance';
            List<User> existingUsername = [
                SELECT Id FROM User
                WHERE Username = :username
                LIMIT 1
            ];
            if (!existingUsername.isEmpty()) {
                username = email + '.'
                         + String.valueOf(System.currentTimeMillis()).substring(8)
                         + '.edvance';
            }

            // Build alias and nickname
            String aliasFirst = String.isBlank(firstName) ? 'u' : firstName.substring(0, 1);
            String aliasLast  = lastName.substring(0, Math.min(4, lastName.length()));
            String alias      = (aliasFirst + aliasLast).left(8);

            String nickname   = email.split('@')[0] + String.valueOf(System.currentTimeMillis()).substring(9);
            if (nickname.length() > 40) {
                nickname = nickname.substring(0, 40);
            }

            List<Profile> communityProfiles = [
                SELECT Id FROM Profile
                WHERE Name = 'Customer Community Plus Login User'
                WITH SYSTEM_MODE
                LIMIT 1
            ];

            if (communityProfiles.isEmpty()) {
                delete con;
                return 'Error: No Community Profile found. Please contact administrator.';
            }

            User u              = new User();
            u.FirstName         = firstName;
            u.LastName          = lastName;
            u.Email             = email;
            u.Username          = username;
            u.CommunityNickname = nickname;
            u.ProfileId         = communityProfiles[0].Id;
            u.ContactId         = con.Id;
            u.Alias             = alias;
            u.TimeZoneSidKey    = 'Asia/Kolkata';
            u.LocaleSidKey      = 'en_IN';
            u.EmailEncodingKey  = 'UTF-8';
            u.LanguageLocaleKey = 'en_US';
            u.User_Type__c      = userType;

            Database.SaveResult sr = Database.insert(u, false, AccessLevel.SYSTEM_MODE);

            if (sr.isSuccess()) {
                System.resetPassword(u.Id, true);
                return 'Success';
            } else {
                String errors = '';
                for (Database.Error err : sr.getErrors()) {
                    errors += err.getMessage() + ' ';
                }
                delete con;
                return 'Error: User creation failed - ' + errors;
            }

        } catch (Exception e) {
            return 'Error: ' + e.getMessage() + ' | Line: ' + e.getLineNumber();
        }
    }
}