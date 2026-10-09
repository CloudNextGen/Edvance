trigger ErrorLogEventTrigger on Error_Log_Event__e (after insert) {
    List<Error_Log__c> logsToInsert = new List<Error_Log__c>();

    for (Error_Log_Event__e evt : Trigger.new) {
        logsToInsert.add(new Error_Log__c(
            Error_Message__c = evt.Error_Message__c,
            Stack_Trace__c   = evt.Stack_Trace__c
        ));
    }

    if (!logsToInsert.isEmpty()) {
        Database.insert(logsToInsert, AccessLevel.SYSTEM_MODE);
    }
}