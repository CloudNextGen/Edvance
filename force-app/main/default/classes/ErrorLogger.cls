public without sharing class ErrorLogger {

    public static void log(Exception e) {
        try {
            EventBus.publish(new Error_Log_Event__e(
                Error_Message__c = e.getMessage(),
                Stack_Trace__c   = e.getStackTraceString()
            ));
        } catch (Exception loggingFailure) {
            System.debug(LoggingLevel.ERROR, 'ErrorLogger failed: ' + loggingFailure.getMessage());
        }
    }
}