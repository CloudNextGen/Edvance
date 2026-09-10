public without sharing class CreateCommunityUserFromFlow {

    // ✅ Allowed User Types from UI
    // HR is NOT in this list — cannot be created from UI
    private static final Set<String> ALLOWED_USER_TYPES = new Set<String>{
        'Mentor',
        'Team Member'
    };

    @AuraEnabled
    public static String createContactAndUser(
        String firstName,
        String lastName,
        String email,
        String phone,
        Id accountId,
        String userType
    ) {
        try {
            // ✅ Step 1: Validate required fields
            if (String.isBlank(firstName) || String.isBlank(lastName) ||
                String.isBlank(email)     || accountId == null ||
                String.isBlank(userType)) {
                return 'Error: All required fields must be filled.';
            }

            // ✅ Step 2: Block HR from being created via UI
            if (!ALLOWED_USER_TYPES.contains(userType)) {
                return 'Error: User Type "' + userType + '" '
                     + 'cannot be created from this form.';
            }

            // ✅ Step 3: Get Account Owner
            // Prevents portal users cannot own partner accounts error
            Account parentAccount = [
                SELECT Id, OwnerId, Owner.UserType
                FROM Account
                WHERE Id = :accountId
                LIMIT 1
            ];

            Id contactOwnerId = parentAccount.OwnerId;

            // ✅ Step 4: If Account Owner is portal user
            // Find internal user to own the Contact
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

            // ✅ Step 5: Create Contact
            Contact con   = new Contact();
            con.FirstName = firstName;
            con.LastName  = lastName;
            con.Email     = email;
            con.Phone     = phone;
            con.AccountId = accountId;
            con.OwnerId   = contactOwnerId;
            insert con;

            // ✅ Step 6: Handle duplicate username
            String username = email + '.portal';
            List<User> existingUsername = [
                SELECT Id FROM User
                WHERE Username = :username
                LIMIT 1
            ];
            if (!existingUsername.isEmpty()) {
                username = email + '.'
                         + String.valueOf(
                               System.currentTimeMillis()
                           ).substring(8)
                         + '.portal';
            }

            // ✅ Step 7: Build alias and nickname
            String aliasFirst = String.isBlank(firstName)
                                ? 'u' : firstName.substring(0,1);
            String aliasLast  = lastName.substring(
                                    0, Math.min(4, lastName.length())
                                );
            String alias      = (aliasFirst + aliasLast).left(8);

            String nickname   = email.split('@')[0]
                              + String.valueOf(
                                    System.currentTimeMillis()
                                ).substring(9);
            if (nickname.length() > 40) {
                nickname = nickname.substring(0, 40);
            }

            // ✅ Step 8: Get Community Profile dynamically
            // Find existing community user's profile
            List<Profile> communityProfiles = [
                SELECT Id FROM Profile
                WHERE Name = 'Customer Community Plus Login User'
                WITH SYSTEM_MODE
                LIMIT 1
            ];

            if (communityProfiles.isEmpty()) {
                delete con;
                return 'Error: No Community Profile found. '
                     + 'Please contact administrator.';
            }

            // ✅ Step 9: Create User with User_Type__c set
            // Flow will pick up User_Type__c and assign Permission Set
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
            u.User_Type__c      = userType; // ✅ Flow uses this to assign PS

            // ✅ Step 10: Insert User
            Database.SaveResult sr = Database.insert(u, false, AccessLevel.SYSTEM_MODE);

            if (sr.isSuccess()) {
                // ✅ Send welcome email
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
            return 'Error: ' + e.getMessage()
                 + ' | Line: ' + e.getLineNumber();
        }
    }
}