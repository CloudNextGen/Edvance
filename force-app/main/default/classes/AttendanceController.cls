/**
 * Employee-facing controller for the attendance LWC.
 * - getTodayRecord: returns today's full punch history + the next action,
 *   so the employee can see their own recorded times without asking anyone.
 * - submitPunch: validates GPS against the office geofence, calculates lateness
 *   where applicable, writes Attendance_Summary__c / Attendance_Log__c, and
 *   attaches the captured photo.
 * - submitAppeal: employee-submitted excusal reason on a Pending late record.
 *   This is the ONLY thing that makes a late record visible to a manager —
 *   see AttendanceApprovalController.
 *
 * Assumes Attendance_Config__mdt (Custom Metadata Type) has fields:
 *   Office_Name__c (Text), Latitude__c (Number), Longitude__c (Number),
 *   Allowed_Radius_Meters__c (Number), Office_Start_Time__c (Text, "HH:MM[:SS]"),
 *   Lunch_Duration_Minutes__c (Number)
 */
public with sharing class AttendanceController {

    private static final Decimal MAX_ACCEPTABLE_ACCURACY_METERS = 100;

    private static final Decimal DEDUCTION_AMOUNT = 50;

    private static final List<String> PUNCH_SEQUENCE = new List<String>{
        'Office Check-In', 'Lunch Check-Out', 'Lunch Check-In', 'Office Check-Out'
    };

    // ---------- Public methods ----------

    @AuraEnabled(cacheable=true)
    public static TodayRecord getTodayRecord() {
        TodayRecord rec = new TodayRecord();
        try {
            Id contactId = getCurrentContactId();
            Date today = Date.today();

            List<Attendance_Log__c> logs = [
                SELECT Id, Type__c, Event_Timestamp__c, Status__c, Late_Minutes__c,
                       Excusal_Reason__c, Deduction_Amount__c
                FROM Attendance_Log__c
                WHERE Employee__c = :contactId
                  AND Is_Valid__c = true
                  AND Attendance_Summary__r.Date__c = :today
                ORDER BY Event_Timestamp__c ASC
            ];

            Map<String, Attendance_Log__c> byType = new Map<String, Attendance_Log__c>();
            for (Attendance_Log__c l : logs) {
                byType.put(l.Type__c, l);
            }

            Attendance_Config__mdt office = getOfficeConfig();

            for (String type : PUNCH_SEQUENCE) {
                PunchEntryDTO entry = new PunchEntryDTO();
                entry.type = type;
                Attendance_Log__c match = byType.get(type);
                if (match != null) {
                    entry.id = match.Id;
                    entry.eventTimestamp = match.Event_Timestamp__c;
                    entry.status = match.Status__c;
                    entry.lateMinutes = match.Late_Minutes__c != null ? Integer.valueOf(match.Late_Minutes__c) : 0;
                    entry.excusalReason = match.Excusal_Reason__c;
                    entry.deductionAmount = match.Deduction_Amount__c;
                    entry.completed = true;
                } else {
                    entry.completed = false;
                }
                entry.eligible = !entry.completed && isEligible(type, byType.keySet());
                entry.needsPhoto = needsPhotoFor(type, office);
                rec.entries.add(entry);
            }
            rec.isDone = byType.keySet().size() == PUNCH_SEQUENCE.size();

        } catch (Exception e) {
            ErrorLogger.log(e);
            AuraHandledException ah = new AuraHandledException(e.getMessage());
            ah.setMessage('Error retrieving today\'s attendance record: ' + e.getMessage());
            throw ah;
        }
        return rec;
    }

    @AuraEnabled
    public static PunchResult submitPunch(String punchType, Double latitude, Double longitude, Double accuracyMeters,
                                           String photoBase64, String contentType) {
        PunchResult result = new PunchResult();
        try {

            if (!PUNCH_SEQUENCE.contains(punchType)) {
                result.success = false;
                result.message = 'Unknown attendance event type.';
                return result;
            }

            Id contactId = getCurrentContactId();
            Contact contactRec = [SELECT Name FROM Contact WHERE Id = :contactId LIMIT 1];
            String contactName = contactRec != null ? contactRec.Name : 'Unknown';
            Date today = Date.today();
            String todayLabel = formatDateLabel(today);

            List<Attendance_Log__c> existingToday = [
                SELECT Type__c FROM Attendance_Log__c
                WHERE Employee__c = :contactId AND Is_Valid__c = true
                  AND Attendance_Summary__r.Date__c = :today
            ];
            Set<String> doneTypes = new Set<String>();
            for (Attendance_Log__c l : existingToday) {
                doneTypes.add(l.Type__c);
            }

            if (doneTypes.contains(punchType)) {
                result.success = false;
                result.message = 'This event has already been recorded today.';
                return result;
            }

            if (!isEligible(punchType, doneTypes)) {
                result.success = false;
                result.message = 'Please complete the prior step first.';
                return result;
            }

            Attendance_Config__mdt office = getOfficeConfig();

            if (needsPhotoFor(punchType, office) && String.isBlank(photoBase64)) {
                result.success = false;
                result.message = 'A photo is required for this event.';
                return result;
            }

            Double distance = AttendanceGeoUtils.distanceMeters(
                latitude, longitude,
                office.Latitude__c != null ? office.Latitude__c.doubleValue() : null,
                office.Longitude__c != null ? office.Longitude__c.doubleValue() : null
            );
            Boolean accuracyOk = accuracyMeters != null && accuracyMeters <= MAX_ACCEPTABLE_ACCURACY_METERS;
            Boolean withinRadius = distance <= office.Allowed_Radius_Meters__c;
            Boolean isValid = punchType == 'Office Check-Out' ? true : accuracyOk && withinRadius;

            Attendance_Summary__c summary = getOrCreateSummary(contactId, today, contactName, todayLabel);

            Attendance_Log__c logRec = new Attendance_Log__c();
            logRec.Attendance_Summary__c = summary.Id;
            logRec.Employee__c = contactId;
            logRec.Name = contactName + ' ' + todayLabel + ' ' + punchType;
            logRec.Type__c = punchType;
            logRec.Event_Timestamp__c = System.now();
            logRec.Latitude__c = latitude;
            logRec.Longitude__c = longitude;
            logRec.Accuracy_Meters__c = accuracyMeters;
            logRec.Distance_From_Office_Meters__c = distance;
            logRec.Is_Valid__c = isValid;

            if (!isValid) {
                logRec.Rejection_Reason__c = !accuracyOk ? 'Your attendance is not captured due to the Poor GPS accuracy, Please try again.' : 'Your attendance is not captured as you are outside the allowed office radius.';
            }

            if (isValid && (punchType == 'Office Check-In' || punchType == 'Lunch Check-In')) {
                Integer lateMinutes = calculateLateMinutes(punchType, office, summary, logRec.Event_Timestamp__c);
                logRec.Late_Minutes__c = lateMinutes;
                if (lateMinutes > 0) {
                    logRec.Status__c = 'Not Excused';
                    logRec.Deduction_Amount__c = DEDUCTION_AMOUNT;
                } else {
                    logRec.Status__c = 'On Time';
                }
            }

            insert logRec;

            if (isValid) {
                updateSummaryTimestamp(summary.Id, punchType, logRec.Event_Timestamp__c);
            }

            if (isValid && String.isNotBlank(photoBase64)) {
                attachPhoto(logRec.Id, photoBase64, contentType);
            }

            result.success = isValid;
            result.punchType = punchType;
            result.distanceMeters = distance;
            result.message = isValid ? (punchType + ' recorded.') : logRec.Rejection_Reason__c;

        } catch (Exception e) {
            ErrorLogger.log(e);
            result.success = false;
            result.message = 'Error: ' + e.getMessage();
        }
        return result;
    }

    @AuraEnabled
    public static void submitAppeal(Id logId, String reason) {
        if (String.isBlank(reason)) {
            throw new AuraHandledException('Please enter a reason before submitting.');
        }
        Id contactId = getCurrentContactId();

        List<Attendance_Log__c> matches = [
            SELECT Id FROM Attendance_Log__c
            WHERE Id = :logId AND Employee__c = :contactId AND Status__c = 'Not Excused' AND Late_Minutes__c > 0 AND Appeal_Submitted__c = false
            LIMIT 1
        ];
        if (matches.isEmpty()) {
            throw new AuraHandledException('This record is not available for appeal.');
        }

        Attendance_Log__c logRec = new Attendance_Log__c(Id = matches[0].Id);
        logRec.Status__c = 'Pending';
        logRec.Excusal_Reason__c = reason;
        logRec.Appeal_Submitted__c = true;
        update logRec;
    }

    @AuraEnabled
    public static HistoryPageResult getHistory(Date startDate, Date endDate, Boolean lateOnly, Integer pageNumber) {
        Id contactId = getCurrentContactId();

        if (startDate == null || endDate == null) {
            throw new AuraHandledException('Start and end date are required.');
        }
        Integer pageSize = 10;
        Integer pageNum = pageNumber != null ? pageNumber : 0;
        Integer offset = pageNum * pageSize;

        String whereClause = 'WHERE Employee__c = :contactId ' +
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
    

    // ---------- Internal logic ----------

    private static String formatDateLabel(Date d) {
        if (d == null) {
            return '';
        }
        return padTwo(d.month()) + '/' + padTwo(d.day()) + '/' + String.valueOf(d.year());
    }

    private static String padTwo(Integer value) {
        if (value == null) {
            return '00';
        }
        return value < 10 ? '0' + String.valueOf(value) : String.valueOf(value);
    }

    private static Attendance_Summary__c getOrCreateSummary(Id contactId, Date today, String contactName, String todayLabel) {
        List<Attendance_Summary__c> existing = [
            SELECT Id, Lunch_Out_Time__c, Name
            FROM Attendance_Summary__c
            WHERE Employee__c = :contactId AND Date__c = :today
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            Attendance_Summary__c existingSummary = existing[0];
            String expectedName = contactName + ' ' + todayLabel;
            if (String.isBlank(existingSummary.Name) || existingSummary.Name != expectedName) {
                existingSummary.Name = expectedName;
                update existingSummary;
            }
            return existingSummary;
        }
        Attendance_Summary__c s = new Attendance_Summary__c(
            Employee__c = contactId,
            Date__c = today,
            Name = contactName + ' ' + todayLabel
        );
        insert s;
        return s;
    }

    private static void updateSummaryTimestamp(Id summaryId, String punchType, Datetime ts) {
        Attendance_Summary__c current = [SELECT Id, Employee__c, Date__c FROM Attendance_Summary__c WHERE Id = :summaryId LIMIT 1];
        Attendance_Summary__c s = new Attendance_Summary__c(Id = summaryId);
        if (punchType == 'Office Check-In') {
            s.Office_Check_In_Time__c = ts;
        } else if (punchType == 'Office Check-Out') {
            s.Office_Check_Out_Time__c = ts;
        } else if (punchType == 'Lunch Check-Out') {
            s.Lunch_Out_Time__c = ts;
        } else if (punchType == 'Lunch Check-In') {
            s.Lunch_In_Time__c = ts;
        }
        // Recompute and set the summary Name to Contact Name + Date
        try {
            Contact contactRec = [SELECT Name FROM Contact WHERE Id = :current.Employee__c LIMIT 1];
            s.Name = (contactRec != null ? contactRec.Name : 'Unknown') + ' ' + formatDateLabel(current.Date__c);
        } catch (Exception e) {
            ErrorLogger.log(e);
            // ignore name recompute failures
        }
        update s;
    }

    private static Integer calculateLateMinutes(String punchType, Attendance_Config__mdt office,
                                                 Attendance_Summary__c summary, Datetime eventTime) {
        Integer diffMinutes = 0;

        if (punchType == 'Office Check-In' && String.isNotBlank(office.Office_Start_Time__c)) {
            try {
                List<String> timeParts = office.Office_Start_Time__c.split(':');
                Integer hour = timeParts.size() > 0 ? Integer.valueOf(timeParts[0]) : 0;
                Integer minute = timeParts.size() > 1 ? Integer.valueOf(timeParts[1]) : 0;
                Integer second = 0;
                if (timeParts.size() > 2) {
                    String secPart = timeParts[2].contains('.') ? timeParts[2].substringBefore('.') : timeParts[2];
                    second = Integer.valueOf(secPart);
                }
                Datetime expectedStart = Datetime.newInstance(
                    Date.today().year(), Date.today().month(), Date.today().day(), hour, minute, second
                );
                diffMinutes = Integer.valueOf((eventTime.getTime() - expectedStart.getTime()) / 60000);
            } catch (Exception e) {
                ErrorLogger.log(e);
                // Malformed Office_Start_Time__c in metadata — fail safe to 0 rather than blocking check-in
                diffMinutes = 0;
            }

        } else if (punchType == 'Lunch Check-In' && summary.Lunch_Out_Time__c != null
                   && office.Lunch_Duration_Minutes__c != null) {
            Datetime allowedReturn = summary.Lunch_Out_Time__c.addMinutes(
                Integer.valueOf(office.Lunch_Duration_Minutes__c)
            );
            diffMinutes = Integer.valueOf((eventTime.getTime() - allowedReturn.getTime()) / 60000);
        }

        return diffMinutes > 0 ? diffMinutes : 0;
    }

    private static void attachPhoto(Id logRecordId, String base64Data, String contentType) {
        String ext = (contentType != null && contentType.contains('png')) ? 'png' : 'jpg';

        ContentVersion cv = new ContentVersion();
        cv.Title = 'Attendance Photo ' + Datetime.now().format('yyyyMMdd_HHmmss');
        cv.PathOnClient = cv.Title + '.' + ext;
        cv.VersionData = EncodingUtil.base64Decode(base64Data);
        insert cv;

        ContentVersion inserted = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

        ContentDocumentLink link = new ContentDocumentLink();
        link.ContentDocumentId = inserted.ContentDocumentId;
        link.LinkedEntityId = logRecordId;
        link.ShareType = 'V';
        link.Visibility = 'AllUsers';
        insert link;
    }

    private static Id getCurrentContactId() {
        User u = [SELECT ContactId FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        if (u.ContactId == null) {
            throw new AuraHandledException('Current user is not linked to a Contact record.');
        }
        return u.ContactId;
    }

    private static Attendance_Config__mdt getOfficeConfig() {
        List<Attendance_Config__mdt> configs = [
            SELECT Latitude__c, Longitude__c, Allowed_Radius_Meters__c,
                   Office_Start_Time__c, Lunch_Duration_Minutes__c, Need_Lunch_Photo__c
            FROM Attendance_Config__mdt
            LIMIT 1
        ];
        if (configs.isEmpty()) {
            throw new AuraHandledException('Office location is not configured.');
        }
        return configs[0];
    }

    private static Boolean isEligible(String type, Set<String> doneTypes) {
        if (type == 'Office Check-In')  return true;
        if (type == 'Lunch Check-Out')  return doneTypes.contains('Office Check-In') && !doneTypes.contains('Office Check-Out');
        if (type == 'Lunch Check-In')   return doneTypes.contains('Lunch Check-Out');
        if (type == 'Office Check-Out') return doneTypes.contains('Office Check-In');
        return false;
    }

    private static Boolean needsPhotoFor(String type, Attendance_Config__mdt office) {
        if (type == 'Office Check-In' || type == 'Office Check-Out') return true;
        return office.Need_Lunch_Photo__c == true;
    }

    // ---------- Wrapper classes ----------

    public class TodayRecord {
        @AuraEnabled public String nextType;
        @AuraEnabled public String buttonLabel;
        @AuraEnabled public Boolean isDone;
        @AuraEnabled public String message;
        @AuraEnabled public List<PunchEntryDTO> entries = new List<PunchEntryDTO>();
    }

    public class PunchEntryDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String type;
        @AuraEnabled public Boolean completed;
        @AuraEnabled public Datetime eventTimestamp;
        @AuraEnabled public String status;
        @AuraEnabled public Integer lateMinutes;
        @AuraEnabled public String excusalReason;
        @AuraEnabled public Decimal deductionAmount;
        @AuraEnabled public Boolean eligible;
        @AuraEnabled public Boolean needsPhoto;
    }

    public class PunchResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String punchType;
        @AuraEnabled public Double distanceMeters;
        @AuraEnabled public String message;
    }

    public class HistoryPageResult {
        @AuraEnabled public List<Attendance_Summary__c> records;
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public Integer pageNumber;
    }
}