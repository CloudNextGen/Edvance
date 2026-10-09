public without sharing class ErrorLogger {
    @TestVisible
    private static Boolean simulatePublishExceptionForTest = false;

    private class SimulatedPublishException extends Exception {}

    public static void log(Exception e) {
        log(e.getMessage(), e.getStackTraceString());
    }

    public static void log(String message) {
        log(message, null);
    }

    private static void log(String message, String stackTrace) {
        Error_Log_Event__e errorEvent = new Error_Log_Event__e(
            Error_Message__c = truncate(message),
            Stack_Trace__c = truncate(stackTrace)
        );

        try {
            if (Test.isRunningTest() && simulatePublishExceptionForTest) {
                throw new SimulatedPublishException();
            }
            Database.SaveResult publishResult = EventBus.publish(errorEvent);
            if (publishResult.isSuccess()) {
                return;
            }
            List<String> publishErrors = new List<String>();
            for (Database.Error publishError : publishResult.getErrors()) {
                publishErrors.add(publishError.getMessage());
            }
            message = String.valueOf(message) + '\nError event publish failed: ' +
                (publishErrors.isEmpty() ? 'No error details were returned.' : String.join(publishErrors, '; '));
        } catch (Exception publishFailure) {
            message = String.valueOf(message) + '\nError event publish failed: ' + publishFailure.getMessage();
            stackTrace = String.valueOf(stackTrace) + '\n' + publishFailure.getStackTraceString();
        }

        Database.insert(new Error_Log__c(
            Error_Message__c = truncate(message),
            Stack_Trace__c = truncate(stackTrace)
        ), AccessLevel.SYSTEM_MODE);
    }

    private static String truncate(String value) {
        if (value == null || value.length() <= 32768) {
            return value;
        }
        return value.substring(0, 32768);
    }
}