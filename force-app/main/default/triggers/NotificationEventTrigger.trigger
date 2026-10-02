trigger NotificationEventTrigger on Send_Email__e (after insert) {
    List<Messaging.SingleEmailMessage> emailsToSend = new List<Messaging.SingleEmailMessage>();
    
    // 1. Safe query: avoids unhandled exception if address is missing
    List<OrgWideEmailAddress> owaList = [
        SELECT Id 
        FROM OrgWideEmailAddress 
        WHERE Address = 'gauravmsplc008@gmail.com' 
        LIMIT 1
    ];
    if (owaList.isEmpty()) {
        owaList = [SELECT Id FROM OrgWideEmailAddress LIMIT 1];
    }

    for (Send_Email__e evt : Trigger.new) {
        if (String.isBlank(evt.Recipient_Emails__c)) {
            continue;
        }

        // Convert comma-separated string to List<String>
        List<String> toAddresses = new List<String>();
        for (String emailStr : evt.Recipient_Emails__c.split(',')) {
            if (String.isNotBlank(emailStr)) {
                toAddresses.add(emailStr.trim());
            }
        }

        // Skip if no valid recipient was parsed
        if (toAddresses.isEmpty()) {
            continue;
        }

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(toAddresses);

        // Process CC Addresses if available
        if (String.isNotBlank(evt.CC_Emails__c)) {
            List<String> ccAddresses = new List<String>();
            for (String ccStr : evt.CC_Emails__c.split(',')) {
                if (String.isNotBlank(ccStr)) {
                    ccAddresses.add(ccStr.trim());
                }
            }
            if (!ccAddresses.isEmpty()) {
                mail.setCcAddresses(ccAddresses);
            }
        }

        mail.setSubject(evt.Subject__c);
        mail.setHtmlBody(evt.Body__c);

        // 2. CRITICAL: Prevents silent drops when running as Automated Process
        mail.setSaveAsActivity(false);
        mail.setUseSignature(false);

        if (!owaList.isEmpty()) {
            mail.setOrgWideEmailAddressId(owaList[0].Id);
        }

        emailsToSend.add(mail);
    }

    if (!emailsToSend.isEmpty()) {
        Messaging.SendEmailResult[] results = Messaging.sendEmail(emailsToSend, false);
        for (Messaging.SendEmailResult res : results) {
            if (!res.isSuccess()) {
                System.debug('Send_Email__e dispatch failed: ' + res.getErrors());
            }
        }
    }
}