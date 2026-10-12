/**
 * Admin-facing controller for the attendance dashboard reached via
 * "View Attendance →" on AdminAssessmentDashboard's user cards.
 * Replaces AttendanceApprovalController — combines pending-appeal review,
 * employee-scoped history, and day-level detail (with attached photos)
 * in one class. Once this is wired into the LWC, AttendanceApprovalController
 * can be deleted.
 */
public with sharing class AttendanceAdminController {
    private static final Decimal DEDUCTION_AMOUNT = 50;
    private static final Integer MONTHLY_LATE_GRACE_DAYS = 3;
    private static final Integer HISTORY_PAGE_SIZE = 10;

    // ---------- Pending appeals (per employee) ----------

    @AuraEnabled
    public static List<Attendance_Log__c> getPendingLateInstances(Id employeeId) {
        String query = 'SELECT Id, Employee__r.Name, Type__c, Event_Timestamp__c, Late_Minutes__c, ' +
                        'Excusal_Reason__c, Deduction_Amount__c, Attendance_Summary__r.Date__c ' +
                        'FROM Attendance_Log__c ' +
                        'WHERE Status__c = \'Pending\' AND Appeal_Submitted__c = true ';
        if (employeeId != null) {
            query += 'AND Employee__c = :employeeId ';
        }
        query += 'ORDER BY Event_Timestamp__c ASC LIMIT 200';
        return Database.query(query);
    }

    @AuraEnabled
    public static List<Attendance_Log__c> getPendingAppealsForDashboard() {
        return getPendingLateInstances(null);
    }

    @AuraEnabled
    public static void reviewLateInstance(Id logId, Boolean approve) {
        if (logId == null) {
            throw new AuraHandledException('Log record is required.');
        }

        List<Attendance_Log__c> logs = [
            SELECT Id, Status__c, Employee__c, Attendance_Summary__r.Date__c
            FROM Attendance_Log__c
            WHERE Id = :logId
            LIMIT 1
        ];
        if (logs.isEmpty()) {
            throw new AuraHandledException('This appeal no longer exists.');
        }
        if (logs[0].Status__c != 'Pending') {
            throw new AuraHandledException('This appeal has already been reviewed.');
        }

        Attendance_Log__c logRec = new Attendance_Log__c(
            Id = logs[0].Id,
            Status__c = approve ? 'Excused' : 'Not Excused',
            Excused_Date__c = System.now()
        );
        if (approve) {
            logRec.Deduction_Amount__c = 0;
            logRec.Excused_By__c = UserInfo.getUserId();
        }

        try {
            update logRec;
            if (approve) {
                recalculateMonthlyDeductions(new Map<Id, Set<Date>>{
                    logs[0].Employee__c => new Set<Date>{
                        logs[0].Attendance_Summary__r.Date__c.toStartOfMonth()
                    }
                });
            }
        } catch (DmlException e) {
            ErrorLogger.log(e);
            AuraHandledException ahe = new AuraHandledException('Could not save the decision: ' + e.getDmlMessage(0));
            ahe.setMessage('Could not save the decision: ' + e.getDmlMessage(0));
            throw ahe;
        }
    }

    @AuraEnabled
    public static Integer reviewSelectedAppeals(List<Id> logIds, Boolean approve) {
        if (logIds == null || logIds.isEmpty()) {
            throw new AuraHandledException('Select at least one appeal to review.');
        }
        if (approve == null) {
            throw new AuraHandledException('Choose whether to approve or reject the selected appeals.');
        }

        Set<Id> selectedIds = new Set<Id>(logIds);
        List<Attendance_Log__c> logs = [
            SELECT Id, Status__c, Employee__c, Attendance_Summary__r.Date__c
            FROM Attendance_Log__c
            WHERE Id IN :selectedIds
        ];
        if (logs.size() != selectedIds.size()) {
            throw new AuraHandledException('One or more selected appeals no longer exist.');
        }

        Map<Id, Set<Date>> affectedMonthsByEmployee = new Map<Id, Set<Date>>();
        List<Attendance_Log__c> logsToUpdate = new List<Attendance_Log__c>();
        for (Attendance_Log__c existingLog : logs) {
            if (existingLog.Status__c != 'Pending') {
                throw new AuraHandledException('One or more selected appeals have already been reviewed.');
            }
            Attendance_Log__c logRec = new Attendance_Log__c(
                Id = existingLog.Id,
                Status__c = approve ? 'Excused' : 'Not Excused',
                Excused_Date__c = System.now()
            );
            if (approve) {
                logRec.Deduction_Amount__c = 0;
                logRec.Excused_By__c = UserInfo.getUserId();
                if (!affectedMonthsByEmployee.containsKey(existingLog.Employee__c)) {
                    affectedMonthsByEmployee.put(existingLog.Employee__c, new Set<Date>());
                }
                affectedMonthsByEmployee.get(existingLog.Employee__c).add(
                    existingLog.Attendance_Summary__r.Date__c.toStartOfMonth()
                );
            }
            logsToUpdate.add(logRec);
        }

        try {
            update logsToUpdate;
            if (approve) {
                recalculateMonthlyDeductions(affectedMonthsByEmployee);
            }
        } catch (DmlException e) {
            ErrorLogger.log(e);
            AuraHandledException ahe = new AuraHandledException('Could not save the decisions: ' + e.getDmlMessage(0));
            ahe.setMessage('Could not save the decisions: ' + e.getDmlMessage(0));
            throw ahe;
        }
        return logs.size();
    }

    private static void recalculateMonthlyDeductions(Map<Id, Set<Date>> affectedMonthsByEmployee) {
        if (affectedMonthsByEmployee.isEmpty()) {
            return;
        }

        Set<Id> employeeIds = affectedMonthsByEmployee.keySet();
        Date firstMonthStart;
        Date lastMonthEnd;
        for (Set<Date> monthStarts : affectedMonthsByEmployee.values()) {
            for (Date monthStart : monthStarts) {
                Date monthEnd = monthStart.addMonths(1).addDays(-1);
                if (firstMonthStart == null || monthStart < firstMonthStart) {
                    firstMonthStart = monthStart;
                }
                if (lastMonthEnd == null || monthEnd > lastMonthEnd) {
                    lastMonthEnd = monthEnd;
                }
            }
        }

        List<Attendance_Log__c> lateLogs = [
            SELECT Id, Employee__c, Type__c, Status__c, Late_Minutes__c, Deduction_Amount__c,
                   Attendance_Summary__r.Date__c
            FROM Attendance_Log__c
            WHERE Employee__c IN :employeeIds
              AND Is_Valid__c = true
              AND Late_Minutes__c > 0
              AND Type__c IN ('Office Check-In', 'Lunch Check-Out')
              AND Attendance_Summary__r.Date__c >= :firstMonthStart
              AND Attendance_Summary__r.Date__c <= :lastMonthEnd
            ORDER BY Employee__c, Attendance_Summary__r.Date__c, Event_Timestamp__c
        ];

        Map<String, Integer> lateOccurrencesByEmployeeMonthAndType = new Map<String, Integer>();
        List<Attendance_Log__c> changedLogs = new List<Attendance_Log__c>();
        for (Attendance_Log__c lateLog : lateLogs) {
            Date attendanceDate = lateLog.Attendance_Summary__r.Date__c;
            Date monthStart = attendanceDate.toStartOfMonth();
            if (!affectedMonthsByEmployee.get(lateLog.Employee__c).contains(monthStart)) {
                continue;
            }

            Decimal expectedDeduction = 0;
            if (lateLog.Status__c != 'Excused' &&
                !AttendanceController.shouldExcludeSaturday(attendanceDate)) {
                String groupKey = String.valueOf(lateLog.Employee__c) + ':' +
                    String.valueOf(monthStart) + ':' + lateLog.Type__c;
                Integer priorLateOccurrences = lateOccurrencesByEmployeeMonthAndType.containsKey(groupKey)
                    ? lateOccurrencesByEmployeeMonthAndType.get(groupKey)
                    : 0;
                expectedDeduction = priorLateOccurrences >= MONTHLY_LATE_GRACE_DAYS
                    ? DEDUCTION_AMOUNT
                    : 0;
                lateOccurrencesByEmployeeMonthAndType.put(groupKey, priorLateOccurrences + 1);
            }

            if (lateLog.Deduction_Amount__c != expectedDeduction) {
                changedLogs.add(new Attendance_Log__c(
                    Id = lateLog.Id,
                    Deduction_Amount__c = expectedDeduction
                ));
            }
        }

        if (!changedLogs.isEmpty()) {
            update changedLogs;
        }
    }

    // ---------- History (per employee) ----------

    @AuraEnabled
    public static HistoryPageResult getHistory(Id employeeId, Date startDate, Date endDate, Boolean lateOnly, Integer pageNumber) {
        if (employeeId == null) {
            throw new AuraHandledException('Employee is required.');
        }
        if (startDate == null || endDate == null) {
            throw new AuraHandledException('Start and end date are required.');
        }
        HistoryPageResult result = new HistoryPageResult();
        Integer pageSize = HISTORY_PAGE_SIZE;
        result.pageSize = pageSize;
        result.pageNumber = pageNumber != null ? pageNumber : 0;
        Integer recordOffset = result.pageNumber * result.pageSize;

        String whereClause = 'WHERE Employee__c = :employeeId ' +
            'AND Date__c >= :startDate AND Date__c <= :endDate ';
        if (lateOnly == true) {
            whereClause += 'AND (Office_Late_Minutes__c > 0 OR Lunch_Late_Minutes__c > 0) ';
        }

        result.totalCount = Database.countQuery(
            'SELECT COUNT() FROM Attendance_Summary__c ' + whereClause
        );
        result.records = Database.query(
            'SELECT Id, Date__c, Office_Check_In_Time__c, Office_Check_Out_Time__c, ' +
            'Lunch_In_Time__c, Lunch_Out_Time__c, Office_Late_Minutes__c, ' +
            'Lunch_Late_Minutes__c, Total_Deduction_Amount__c, ' +
            '(SELECT Status__c FROM Attendance_Logs__r WHERE Late_Minutes__c > 0) ' +
            'FROM Attendance_Summary__c ' + whereClause +
            'ORDER BY Date__c DESC LIMIT :pageSize OFFSET :recordOffset'
        );
        return result;
    }

    // ---------- Day detail (4 events + photos) ----------

    @AuraEnabled
    public static List<DayEventDTO> getDayDetail(Id summaryId) {
        if (summaryId == null) {
            throw new AuraHandledException('Summary record is required.');
        }

        List<Attendance_Log__c> logs = [
            SELECT Id, Type__c, Event_Timestamp__c, Status__c, Late_Minutes__c,
                   Excusal_Reason__c, Deduction_Amount__c
            FROM Attendance_Log__c
            WHERE Attendance_Summary__c = :summaryId AND Is_Valid__c = true
            ORDER BY Event_Timestamp__c ASC
        ];

        Map<Id, Id> logIdToDocId = new Map<Id, Id>();
        if (!logs.isEmpty()) {
            Set<Id> logIds = new Set<Id>();
            for (Attendance_Log__c l : logs) {
                logIds.add(l.Id);
            }
            for (ContentDocumentLink link : [
                SELECT LinkedEntityId, ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId IN :logIds
            ]) {
                logIdToDocId.put(link.LinkedEntityId, link.ContentDocumentId);
            }
        }

        Map<Id, Id> docIdToVersionId = new Map<Id, Id>();
        if (!logIdToDocId.isEmpty()) {
            for (ContentVersion v : [
                SELECT Id, ContentDocumentId
                FROM ContentVersion
                WHERE ContentDocumentId IN :logIdToDocId.values() AND IsLatest = true
            ]) {
                docIdToVersionId.put(v.ContentDocumentId, v.Id);
            }
        }

        List<DayEventDTO> result = new List<DayEventDTO>();
        for (Attendance_Log__c l : logs) {
            DayEventDTO dto = new DayEventDTO();
            dto.logId = l.Id;
            dto.type = l.Type__c;
            dto.eventTimestamp = l.Event_Timestamp__c;
            dto.status = l.Status__c;
            dto.lateMinutes = l.Late_Minutes__c != null ? Integer.valueOf(l.Late_Minutes__c) : 0;
            dto.excusalReason = l.Excusal_Reason__c;
            dto.deductionAmount = l.Deduction_Amount__c;

            Id docId = logIdToDocId.get(l.Id);
            if (docId != null) {
                Id versionId = docIdToVersionId.get(docId);
                if (versionId != null) {
                    dto.contentVersionId = versionId;
                    dto.photoUrl = '/sfc/servlet.shepherd/version/download/' + versionId;
                }
            }
            result.add(dto);
        }
        return result;
    }

    public class DayEventDTO {
        @AuraEnabled public Id logId;
        @AuraEnabled public String type;
        @AuraEnabled public Datetime eventTimestamp;
        @AuraEnabled public String status;
        @AuraEnabled public Integer lateMinutes;
        @AuraEnabled public String excusalReason;
        @AuraEnabled public Decimal deductionAmount;
        @AuraEnabled public Id contentVersionId;
        @AuraEnabled public String photoUrl;
    }

    public class HistoryPageResult {
        @AuraEnabled public List<Attendance_Summary__c> records;
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public Integer pageNumber;
    }
}