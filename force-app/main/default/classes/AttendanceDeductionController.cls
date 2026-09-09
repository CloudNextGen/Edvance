public with sharing class AttendanceDeductionController {

    public class DeductionSummaryWrapper {
        @AuraEnabled public String employeeId { get; set; }
        @AuraEnabled public String employeeName { get; set; }
        @AuraEnabled public Decimal totalDeductionAmount { get; set; }
        @AuraEnabled public Decimal offLateMinutes { get; set; }
        @AuraEnabled public Decimal lunchLateMinutes { get; set; }
        @AuraEnabled public Integer officeLateDays { get; set; }
        @AuraEnabled public Integer lunchLateDays { get; set; }
        @AuraEnabled public String attendanceSummaryId { get; set; }
        @AuraEnabled public String attendanceSummaryDate { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<DeductionSummaryWrapper> getTopDeductionsEmployees() {
        List<DeductionSummaryWrapper> resultList = new List<DeductionSummaryWrapper>();

        try {
            // Group totals by unique Employee ID
            List<AggregateResult> groupedResults = [
                SELECT 
                    Employee__c empId,
                    SUM(Total_Deduction_Amount__c) totalDeduction,
                    SUM(Office_Late_Minutes__c) totalOfficeLate,
                    SUM(Lunch_Late_Minutes__c) totalLunchLate
                FROM Attendance_Summary__c
                WHERE Total_Deduction_Amount__c > 0
                WITH SYSTEM_MODE
                GROUP BY Employee__c
                ORDER BY SUM(Total_Deduction_Amount__c) DESC
                LIMIT 3
            ];

            if (!groupedResults.isEmpty()) {
                Set<Id> empIds = new Set<Id>();
                for (AggregateResult ar : groupedResults) {
                    if (ar.get('empId') != null) {
                        empIds.add((Id) ar.get('empId'));
                    }
                }

                // Fetch Employee names
                Map<Id, String> employeeNameMap = new Map<Id, String>();
                for (Contact c : [SELECT Id, Name FROM Contact WHERE Id IN :empIds WITH SYSTEM_MODE]) {
                    employeeNameMap.put(c.Id, c.Name);
                }

                // Count days employee was late (> 0 minutes)
                Map<Id, Integer> officeLateDaysMap = new Map<Id, Integer>();
                Map<Id, Integer> lunchLateDaysMap = new Map<Id, Integer>();

                for (AggregateResult arLate : [
                    SELECT Employee__c empId, COUNT(Id) totalDays 
                    FROM Attendance_Summary__c 
                    WHERE Employee__c IN :empIds AND Office_Late_Minutes__c > 0 
                    WITH SYSTEM_MODE 
                    GROUP BY Employee__c
                ]) {
                    officeLateDaysMap.put((Id) arLate.get('empId'), (Integer) arLate.get('totalDays'));
                }

                for (AggregateResult arLate : [
                    SELECT Employee__c empId, COUNT(Id) totalDays 
                    FROM Attendance_Summary__c 
                    WHERE Employee__c IN :empIds AND Lunch_Late_Minutes__c > 0 
                    WITH SYSTEM_MODE 
                    GROUP BY Employee__c
                ]) {
                    lunchLateDaysMap.put((Id) arLate.get('empId'), (Integer) arLate.get('totalDays'));
                }

                // Get latest record date
                Map<Id, Attendance_Summary__c> latestRecordMap = new Map<Id, Attendance_Summary__c>();
                for (Attendance_Summary__c rec : [
                    SELECT Id, Employee__c, Date__c
                    FROM Attendance_Summary__c
                    WHERE Employee__c IN :empIds
                    WITH SYSTEM_MODE
                    ORDER BY Date__c DESC
                ]) {
                    if (!latestRecordMap.containsKey(rec.Employee__c)) {
                        latestRecordMap.put(rec.Employee__c, rec);
                    }
                }

                // Build Wrapper Response
                for (AggregateResult ar : groupedResults) {
                    Id empId = (Id) ar.get('empId');
                    if (empId == null) continue;

                    Attendance_Summary__c latestRec = latestRecordMap.get(empId);

                    DeductionSummaryWrapper wrapper = new DeductionSummaryWrapper();
                    wrapper.employeeId = empId;
                    wrapper.employeeName = employeeNameMap.containsKey(empId) ? employeeNameMap.get(empId) : 'Employee Record';
                    wrapper.totalDeductionAmount = (Decimal) ar.get('totalDeduction');
                    wrapper.offLateMinutes = (Decimal) ar.get('totalOfficeLate');
                    wrapper.lunchLateMinutes = (Decimal) ar.get('totalLunchLate');
                    wrapper.officeLateDays = officeLateDaysMap.containsKey(empId) ? officeLateDaysMap.get(empId) : 0;
                    wrapper.lunchLateDays = lunchLateDaysMap.containsKey(empId) ? lunchLateDaysMap.get(empId) : 0;

                    if (latestRec != null) {
                        wrapper.attendanceSummaryId = latestRec.Id;
                        wrapper.attendanceSummaryDate = latestRec.Date__c != null ? String.valueOf(latestRec.Date__c) : '';
                    }

                    resultList.add(wrapper);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AttendanceDeductionController.getTopDeductionsEmployees failed: ' + e.getMessage());
            throw new AuraHandledException(e.getMessage());
        }

        return resultList;
    }
}