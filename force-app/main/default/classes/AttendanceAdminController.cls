/**
 * Admin-facing controller for the attendance dashboard reached via
 * "View Attendance →" on AdminAssessmentDashboard's user cards.
 * Replaces AttendanceApprovalController — combines pending-appeal review,
 * employee-scoped history, and day-level detail (with attached photos)
 * in one class. Once this is wired into the LWC, AttendanceApprovalController
 * can be deleted.
 */
public with sharing class AttendanceAdminController {

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
    public static void reviewLateInstance(Id logId, Boolean approve) {
        if (logId == null) {
            throw new AuraHandledException('Log record is required.');
        }

        List<Attendance_Log__c> logs = [
            SELECT Id, Status__c
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

        Attendance_Log__c logRec = logs[0];
        logRec.Status__c = approve ? 'Excused' : 'Not Excused';
        logRec.Excused_Date__c = System.now();
        if (approve) {
            logRec.Deduction_Amount__c = 0;
            logRec.Excused_By__c = UserInfo.getUserId();
        }

        try {
            update logRec;
        } catch (DmlException e) {
            ErrorLogger.log(e);
            AuraHandledException ahe = new AuraHandledException('Could not save the decision: ' + e.getDmlMessage(0));
            ahe.setMessage('Could not save the decision: ' + e.getDmlMessage(0));
            throw ahe;
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
        Integer pageSize = 10;
        Integer pageNum = pageNumber != null ? pageNumber : 0;
        Integer offset = pageNum * pageSize;

        String whereClause = 'WHERE Employee__c = :employeeId ' +
                            'AND Date__c >= :startDate AND Date__c <= :endDate ';
        if (lateOnly) {
            whereClause += 'AND (Office_Late_Minutes__c > 0 OR Lunch_Late_Minutes__c > 0) ';
        }

        Integer totalCount = Database.countQuery(
            'SELECT COUNT() FROM Attendance_Summary__c ' + whereClause
        );

        String query = 'SELECT Id, Date__c, Office_Check_In_Time__c, Office_Check_Out_Time__c, ' +
                        'Lunch_Out_Time__c, Lunch_In_Time__c, Office_Late_Minutes__c, ' +
                        'Lunch_Late_Minutes__c, Total_Deduction_Amount__c, ' +
                        '(SELECT Status__c FROM Attendance_Logs__r WHERE Late_Minutes__c > 0) ' +
                        'FROM Attendance_Summary__c ' + whereClause +
                        'ORDER BY Date__c DESC LIMIT :pageSize OFFSET :offset';

        HistoryPageResult result = new HistoryPageResult();
        result.records = Database.query(query);
        result.totalCount = totalCount;
        result.pageSize = pageSize;
        result.pageNumber = pageNum;
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