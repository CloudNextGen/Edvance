public with sharing class EmailEventPublisher {
    
    /**
     * Publishes a single generic email platform event
     */
    public static Database.SaveResult publishEmail(
        List<String> toAddresses, 
        List<String> ccAddresses, 
        String subject, 
        String body
    ) {
        Send_Email__e emailEvent = new Send_Email__e(
            Recipient_Emails__c = toAddresses != null ? String.join(toAddresses, ',') : null,
            CC_Emails__c        = ccAddresses != null ? String.join(ccAddresses, ',') : null,
            Subject__c         = subject,
            Body__c            = body
        );
        
        return EventBus.publish(emailEvent);
    }
}