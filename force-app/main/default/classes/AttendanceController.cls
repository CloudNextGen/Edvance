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
 * Punch order: Office Check-In -> Lunch Check-In (lunch STARTS, shown as "Lunch In")
 *              -> Lunch Check-Out (lunch ENDS, shown as "Lunch Out") -> Office Check-Out.
 * Lunch lateness is measured on 'Lunch Check-Out': the time the employee returns
 * versus the Lunch Check-In time + Lunch_Duration_Minutes__c.
 *
 * Photos: required for Office Check-In only. Office Check-Out needs no photo.
 * Lunch In / Lunch Out follow Need_Lunch_Photo__c.
 *
 * Saturday lateness can be excluded through Assessment_Portal_Config__mdt.Exclude_Saturday__c.
 *
 * Assumes Attendance_Config__mdt (Custom Metadata Type) has fields:
 *   Office_Name__c (Text), Latitude__c (Number), Longitude__c (Number),
 *   Allowed_Radius_Meters__c (Number), Office_Start_Time__c (Text, "HH:MM[:SS]"),
 *   Lunch_Duration_Minutes__c (Number)
 */
public with sharing class AttendanceController {
    private static final Integer HISTORY_PAGE_SIZE = 10;

    private static final Decimal MAX_ACCEPTABLE_ACCURACY_METERS = 100;

    private static final Decimal DEDUCTION_AMOUNT = 50;
    private static final Integer MONTHLY_LATE_GRACE_DAYS = 3;
    @TestVisible private static Boolean excludeSaturdayOverride;
    @TestVisible private static Id currentContactIdOverride;
    @TestVisible private static Datetime officeCheckInNowOverride;
    @TestVisible private static BusinessHours defaultBusinessHoursOverride;

    // Lunch Check-In = lunch starts, Lunch Check-Out = lunch ends
    private static final List<String> PUNCH_SEQUENCE = new List<String>{
        'Office Check-In', 'Lunch Check-In', 'Lunch Check-Out', 'Office Check-Out'
    };

    // ---------- Public methods ----------

    @AuraEnabled(cacheable=true)
    public static TodayRecord getTodayRecord() {
        TodayRecord rec = new TodayRecord();
        try {
            Id contactId = getCurrentContactId();
            Date today = Date.today();

            Attendance_Config__mdt office = getOfficeConfig();
            rec.nextOfficeCheckInOpensAt = getNextOfficeCheckInOpensAt(today, office);
            List<Attendance_Log__c> logs = getValidAttendanceLogs(contactId, today);
            Boolean carryingOverPreviousShift = false;
            if (!containsPunchType(logs, 'Office Check-In') &&
                isBeforeOfficeCheckInOpens(today, office)) {
                List<Attendance_Log__c> previousDayLogs = getValidAttendanceLogs(contactId, today.addDays(-1));
                if (containsPunchType(previousDayLogs, 'Office Check-In') &&
                    !containsPunchType(previousDayLogs, 'Office Check-Out')) {
                    logs = previousDayLogs;
                    carryingOverPreviousShift = true;
                }
            }

            Map<String, Attendance_Log__c> byType = new Map<String, Attendance_Log__c>();
            for (Attendance_Log__c l : logs) {
                byType.put(l.Type__c, l);
            }

            rec.lunchDurationMinutes = office.Lunch_Duration_Minutes__c;

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
                if (carryingOverPreviousShift) {
                    entry.eligible = !entry.completed && type == 'Office Check-Out';
                }
                entry.needsPhoto = needsPhotoFor(type, office);
                if (type == 'Office Check-In') {
                    entry.officeCheckInOpensAt = getOfficeCheckInOpensAt(today, office);
                }
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
            Date attendanceDate = today;

            Attendance_Config__mdt office = getOfficeConfig();
            List<Attendance_Log__c> existingToday = getValidAttendanceLogs(contactId, today);
            if (punchType == 'Office Check-Out' &&
                !containsPunchType(existingToday, 'Office Check-In') &&
                isBeforeOfficeCheckInOpens(today, office)) {
                List<Attendance_Log__c> previousDayLogs = getValidAttendanceLogs(contactId, today.addDays(-1));
                if (containsPunchType(previousDayLogs, 'Office Check-In') &&
                    !containsPunchType(previousDayLogs, 'Office Check-Out')) {
                    existingToday = previousDayLogs;
                    attendanceDate = today.addDays(-1);
                }
            }
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

            if (punchType == 'Office Check-In' && !isOfficeCheckInOpen(today, office)) {
                Datetime opensAt = getOfficeCheckInOpensAt(today, office);
                result.success = false;
                result.message = 'Office Check-In opens at ' + opensAt.format('h:mm a') + '.';
                return result;
            }

            if (needsPhotoFor(punchType, office) && String.isBlank(photoBase64)) {
                result.success = false;
                result.message = 'A photo is required for this event.';
                return result;
            }

            Double distance = new AttendanceGeoUtils().distanceMeters(
                latitude, longitude,
                office.Latitude__c != null ? office.Latitude__c.doubleValue() : null,
                office.Longitude__c != null ? office.Longitude__c.doubleValue() : null
            );
            Boolean accuracyOk = accuracyMeters != null && accuracyMeters <= MAX_ACCEPTABLE_ACCURACY_METERS;
            Boolean withinRadius = distance <= office.Allowed_Radius_Meters__c;
            Boolean isValid = punchType == 'Office Check-Out' ? true : accuracyOk && withinRadius;

            Attendance_Summary__c summary = getOrCreateSummary(
                contactId, attendanceDate, contactName, formatDateLabel(attendanceDate)
            );

            Attendance_Log__c logRec = new Attendance_Log__c();
            logRec.Attendance_Summary__c = summary.Id;
            logRec.Employee__c = contactId;
            logRec.Name = contactName + ' ' + formatDateLabel(attendanceDate) + ' ' + punchType;
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

            // Office and lunch lateness each have their own monthly three-occurrence grace.
            if (isValid && (punchType == 'Office Check-In' || punchType == 'Lunch Check-Out')) {
                Integer lateMinutes = calculateLateMinutes(
                    punchType, office, summary, logRec.Event_Timestamp__c, attendanceDate
                );
                logRec.Late_Minutes__c = lateMinutes;
                if (lateMinutes > 0) {
                    logRec.Status__c = 'Not Excused';
                    logRec.Deduction_Amount__c = isBeyondMonthlyLateGrace(contactId, today, punchType)
                        ? DEDUCTION_AMOUNT
                        : 0;
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

        try {
            Id contactId = getCurrentContactId();
            List<Attendance_Log__c> matches = [
                SELECT Id, Type__c, Late_Minutes__c, Employee__r.Name
                FROM Attendance_Log__c
                WHERE Id = :logId AND Employee__c = :contactId AND Status__c = 'Not Excused'
                    AND Late_Minutes__c > 0 AND Appeal_Submitted__c = false
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
            notifyAttendanceAppealReviewers(matches[0]);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            ErrorLogger.log(e);
            AuraHandledException handledException = new AuraHandledException(
                'Unable to submit the attendance appeal. Please try again or contact your administrator.'
            );
            handledException.setMessage(
                'Unable to submit the attendance appeal. Please try again or contact your administrator.'
            );
            throw handledException;
        }
    }

    private static void notifyAttendanceAppealReviewers(Attendance_Log__c appeal) {
        try {
            List<CustomNotificationType> notificationTypes = [
                SELECT Id
                FROM CustomNotificationType
                WHERE DeveloperName = 'Attendance_Appeal_Submitted'
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            List<CustomPermission> permissions = [
                SELECT Id
                FROM CustomPermission
                WHERE DeveloperName = 'View_Attendance'
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (notificationTypes.isEmpty() || permissions.isEmpty()) return;

            Set<Id> grantedPermissionSetIds = new Set<Id>();
            for (SetupEntityAccess grant : [
                SELECT ParentId
                FROM SetupEntityAccess
                WHERE SetupEntityId = :permissions[0].Id
                WITH SYSTEM_MODE
            ]) {
                grantedPermissionSetIds.add(grant.ParentId);
            }
            if (grantedPermissionSetIds.isEmpty()) return;

            Set<Id> profileIds = new Set<Id>();
            Set<Id> assignedPermissionSetIds = new Set<Id>();
            for (PermissionSet permissionSet : [
                SELECT Id, IsOwnedByProfile, ProfileId
                FROM PermissionSet
                WHERE Id IN :grantedPermissionSetIds
                WITH SYSTEM_MODE
            ]) {
                if (permissionSet.IsOwnedByProfile && permissionSet.ProfileId != null) {
                    profileIds.add(permissionSet.ProfileId);
                } else {
                    assignedPermissionSetIds.add(permissionSet.Id);
                }
            }

            Set<Id> recipientIds = new Set<Id>();
            if (!assignedPermissionSetIds.isEmpty()) {
                for (PermissionSetAssignment assignment : [
                    SELECT AssigneeId
                    FROM PermissionSetAssignment
                    WHERE PermissionSetId IN :assignedPermissionSetIds
                      AND Assignee.IsActive = true
                    WITH SYSTEM_MODE
                ]) {
                    recipientIds.add(assignment.AssigneeId);
                }

                Set<Id> permissionSetGroupIds = new Set<Id>();
                for (PermissionSetGroupComponent component : [
                    SELECT PermissionSetGroupId
                    FROM PermissionSetGroupComponent
                    WHERE PermissionSetId IN :assignedPermissionSetIds
                    WITH SYSTEM_MODE
                ]) {
                    permissionSetGroupIds.add(component.PermissionSetGroupId);
                }
                if (!permissionSetGroupIds.isEmpty()) {
                    for (PermissionSetAssignment assignment : [
                        SELECT AssigneeId
                        FROM PermissionSetAssignment
                        WHERE PermissionSetGroupId IN :permissionSetGroupIds
                          AND Assignee.IsActive = true
                        WITH SYSTEM_MODE
                    ]) {
                        recipientIds.add(assignment.AssigneeId);
                    }
                }
            }
            if (!profileIds.isEmpty()) {
                for (User permittedUser : [
                    SELECT Id
                    FROM User
                    WHERE ProfileId IN :profileIds AND IsActive = true
                    WITH SYSTEM_MODE
                ]) {
                    recipientIds.add(permittedUser.Id);
                }
            }

            recipientIds.remove(UserInfo.getUserId());
            if (recipientIds.isEmpty()) return;

            Set<String> notificationRecipientIds = new Set<String>();
            for (Id recipientId : recipientIds) {
                notificationRecipientIds.add(String.valueOf(recipientId));
            }

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setTitle('New attendance appeal');
            notification.setBody(appeal.Employee__r.Name + ' submitted an appeal for ' + appeal.Type__c +
                ' (' + appeal.Late_Minutes__c + ' minutes late).');
            notification.setNotificationTypeId(notificationTypes[0].Id);
            notification.setTargetId(appeal.Id);
            notification.send(notificationRecipientIds);
        } catch (Exception e) {
            // A notification failure must not prevent the employee from submitting their appeal.
            ErrorLogger.log(e);
        }
    }

    @AuraEnabled
    public static HistoryPageResult getHistory(Date startDate, Date endDate, Boolean lateOnly, Integer pageNumber) {
        Id contactId = getCurrentContactId();

        if (startDate == null || endDate == null) {
            throw new AuraHandledException('Start and end date are required.');
        }
        HistoryPageResult result = new HistoryPageResult();
        Integer pageSize = HISTORY_PAGE_SIZE;
        result.pageSize = pageSize;
        result.pageNumber = pageNumber != null ? pageNumber : 0;
        Integer recordOffset = result.pageNumber * result.pageSize;

        String whereClause = 'WHERE Employee__c = :contactId ' +
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
        // Lunch_In_Time__c (lunch start) is needed to compute lateness on Lunch Check-Out
        List<Attendance_Summary__c> existing = [
            SELECT Id, Lunch_In_Time__c, Name
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
        } else if (punchType == 'Lunch Check-In') {
            s.Lunch_In_Time__c = ts;
        } else if (punchType == 'Lunch Check-Out') {
            s.Lunch_Out_Time__c = ts;
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

    @TestVisible
    public static Boolean shouldExcludeSaturday(Date attendanceDate) {
        Boolean excludeSaturday = excludeSaturdayOverride;
        if (excludeSaturday == null) {
            List<Assessment_Portal_Config__mdt> configs = [
                SELECT Exclude_Saturday__c
                FROM Assessment_Portal_Config__mdt
                LIMIT 1
            ];
            excludeSaturday = !configs.isEmpty() && configs[0].Exclude_Saturday__c == true;
        }
        return excludeSaturday && attendanceDate != null && isSaturday(attendanceDate);
    }

    private static Boolean isSaturday(Date attendanceDate) {
        if (attendanceDate == null) {
            return false;
        }
        Datetime midnight = Datetime.newInstance(attendanceDate, Time.newInstance(0, 0, 0, 0));
        return midnight.format('E') == 'Sat';
    }

    @TestVisible
    private static Integer calculateLateMinutes(String punchType, Attendance_Config__mdt office,
                                                 Attendance_Summary__c summary, Datetime eventTime,
                                                 Date attendanceDate) {
        Integer diffMinutes = 0;

        // Keep the attendance punch and timestamps, but do not treat it as late
        // (or let it trigger a deduction) when Saturday exclusion is configured.
        if (shouldExcludeSaturday(attendanceDate)) {
            return 0;
        }

        if (punchType == 'Office Check-In') {
            Datetime expectedStart = getBusinessHoursOpeningDateTime(attendanceDate);
            if (expectedStart != null) {
                diffMinutes = Integer.valueOf((eventTime.getTime() - expectedStart.getTime()) / 60000);
            }

        } else if (punchType == 'Lunch Check-Out' && summary.Lunch_In_Time__c != null
                   && office.Lunch_Duration_Minutes__c != null) {
            // Lunch started at Lunch_In_Time__c; employee must be back by start + allowed duration
            Datetime allowedReturn = summary.Lunch_In_Time__c.addMinutes(
                Integer.valueOf(office.Lunch_Duration_Minutes__c)
            );
            diffMinutes = Integer.valueOf((eventTime.getTime() - allowedReturn.getTime()) / 60000);
        }

        return diffMinutes > 0 ? diffMinutes : 0;
    }

    private static Datetime getBusinessHoursOpeningDateTime(Date attendanceDate) {
        if (attendanceDate == null) {
            return null;
        }

        BusinessHours schedule = defaultBusinessHoursOverride;
        if (schedule == null) {
            List<BusinessHours> defaultHours = [
                SELECT TimeZoneSidKey, MondayStartTime, TuesdayStartTime, WednesdayStartTime,
                       ThursdayStartTime, FridayStartTime, SaturdayStartTime, SundayStartTime
                FROM BusinessHours
                WHERE IsDefault = true
                LIMIT 1
            ];
            if (defaultHours.isEmpty()) {
                return null;
            }
            schedule = defaultHours[0];
        }

        Integer weekday = Integer.valueOf(
            Math.mod(Date.newInstance(1900, 1, 1).daysBetween(attendanceDate), 7)
        );
        Time openingTime;
        switch on weekday {
            when 0 { openingTime = schedule.MondayStartTime; }
            when 1 { openingTime = schedule.TuesdayStartTime; }
            when 2 { openingTime = schedule.WednesdayStartTime; }
            when 3 { openingTime = schedule.ThursdayStartTime; }
            when 4 { openingTime = schedule.FridayStartTime; }
            when 5 { openingTime = schedule.SaturdayStartTime; }
            when 6 { openingTime = schedule.SundayStartTime; }
            when else { return null; }
        }
        if (openingTime == null || String.isBlank(schedule.TimeZoneSidKey)) {
            return null;
        }

        Datetime wallTimeUtc = Datetime.newInstanceGmt(attendanceDate, openingTime);
        TimeZone businessTimeZone = TimeZone.getTimeZone(schedule.TimeZoneSidKey);
        Integer offsetMillis = businessTimeZone.getOffset(wallTimeUtc);
        Datetime openingDateTime = wallTimeUtc.addSeconds((-offsetMillis) / 1000);
        Integer adjustedOffsetMillis = businessTimeZone.getOffset(openingDateTime);
        if (adjustedOffsetMillis != offsetMillis) {
            openingDateTime = wallTimeUtc.addSeconds((-adjustedOffsetMillis) / 1000);
        }
        return openingDateTime;
    }

    @TestVisible
    private static Datetime getOfficeCheckInOpensAt(Date attendanceDate, Attendance_Config__mdt office) {
        if (office == null || String.isBlank(office.Office_Start_Time__c)) {
            return null;
        }
        return getOfficeStartDateTime(attendanceDate, office).addHours(-2);
    }

    private static Datetime getOfficeStartDateTime(Date attendanceDate, Attendance_Config__mdt office) {
        List<String> timeParts = office.Office_Start_Time__c.split(':');
        if (timeParts.size() < 2 || timeParts.size() > 3) {
            throw new IllegalArgumentException('Office_Start_Time__c must use HH:mm or HH:mm:ss.');
        }
        Integer hour = Integer.valueOf(timeParts[0]);
        Integer minute = Integer.valueOf(timeParts[1]);
        Integer second = 0;
        if (timeParts.size() == 3) {
            String secPart = timeParts[2].contains('.') ? timeParts[2].substringBefore('.') : timeParts[2];
            second = Integer.valueOf(secPart);
        }
        return Datetime.newInstance(
            attendanceDate.year(), attendanceDate.month(), attendanceDate.day(),
            hour, minute, second
        );
    }

    @TestVisible
    private static Boolean isOfficeCheckInOpen(Date attendanceDate, Attendance_Config__mdt office) {
        Datetime opensAt = getOfficeCheckInOpensAt(attendanceDate, office);
        return opensAt == null || (officeCheckInNowOverride != null
            ? officeCheckInNowOverride >= opensAt
            : System.now() >= opensAt);
    }

    private static Boolean isBeforeOfficeCheckInOpens(
        Date attendanceDate,
        Attendance_Config__mdt office
    ) {
        Datetime opensAt = getOfficeCheckInOpensAt(attendanceDate, office);
        return opensAt != null && (officeCheckInNowOverride != null
            ? officeCheckInNowOverride < opensAt
            : System.now() < opensAt);
    }

    private static Datetime getNextOfficeCheckInOpensAt(
        Date attendanceDate,
        Attendance_Config__mdt office
    ) {
        Datetime nowValue = officeCheckInNowOverride != null
            ? officeCheckInNowOverride
            : System.now();
        Datetime todayOpensAt = getOfficeCheckInOpensAt(attendanceDate, office);
        Date nextOpeningDate = todayOpensAt != null && nowValue >= todayOpensAt
            ? attendanceDate.addDays(1)
            : attendanceDate;
        return getOfficeCheckInOpensAt(nextOpeningDate, office);
    }

    private static List<Attendance_Log__c> getValidAttendanceLogs(Id contactId, Date attendanceDate) {
        return [
            SELECT Id, Type__c, Event_Timestamp__c, Status__c, Late_Minutes__c,
                   Excusal_Reason__c, Deduction_Amount__c
            FROM Attendance_Log__c
            WHERE Employee__c = :contactId
              AND Is_Valid__c = true
              AND Attendance_Summary__r.Date__c = :attendanceDate
            ORDER BY Event_Timestamp__c ASC
        ];
    }

    private static Boolean containsPunchType(List<Attendance_Log__c> logs, String punchType) {
        for (Attendance_Log__c logRec : logs) {
            if (logRec.Type__c == punchType) {
                return true;
            }
        }
        return false;
    }

    // Office and lunch lateness each use their own first three monthly late occurrences.
    @TestVisible
    private static Boolean isBeyondMonthlyLateGrace(Id employeeId, Date lateDate, String punchType) {
        Date monthStart = lateDate.toStartOfMonth();
        Integer priorLateOccurrences = 0;

        for (Attendance_Log__c lateLog : [
            SELECT Attendance_Summary__r.Date__c
            FROM Attendance_Log__c
            WHERE Employee__c = :employeeId
              AND Is_Valid__c = true
              AND Late_Minutes__c > 0
              AND Type__c = :punchType
              AND (Status__c = null OR Status__c != 'Excused')
              AND Attendance_Summary__r.Date__c >= :monthStart
              AND Attendance_Summary__r.Date__c <= :lateDate
        ]) {
            Date recordedLateDate = lateLog.Attendance_Summary__r.Date__c;
            if (shouldExcludeSaturday(recordedLateDate)) {
                continue;
            }
            if (recordedLateDate < lateDate) {
                priorLateOccurrences++;
            }
        }

        return priorLateOccurrences >= MONTHLY_LATE_GRACE_DAYS;
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
        if (currentContactIdOverride != null) {
            return currentContactIdOverride;
        }
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
        // Lunch starts after office check-in, and not once the day is closed
        if (type == 'Lunch Check-In')   return doneTypes.contains('Office Check-In') && !doneTypes.contains('Office Check-Out');
        // Lunch ends only after lunch has started
        if (type == 'Lunch Check-Out')  return doneTypes.contains('Lunch Check-In');
        if (type == 'Office Check-Out') return doneTypes.contains('Office Check-In');
        return false;
    }

    private static Boolean needsPhotoFor(String type, Attendance_Config__mdt office) {
        // Photo is mandatory only for Office Check-In. Office Check-Out needs no photo.
        // Lunch In / Lunch Out follow the Need_Lunch_Photo__c setting in Attendance_Config__mdt.
        if (type == 'Office Check-In') return true;
        if (type == 'Office Check-Out') return false;
        return office.Need_Lunch_Photo__c == true;
    }

    @TestVisible
    private class AttendanceGeoUtils {
        private final Double earthRadiusMeters = 6371000.0;

        @TestVisible
        private Double distanceMeters(Double lat1, Double lon1, Double lat2, Double lon2) {
            Double dLat = toRadians(lat2 - lat1);
            Double dLon = toRadians(lon2 - lon1);

            Double a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
                + Math.cos(toRadians(lat1)) * Math.cos(toRadians(lat2))
                * Math.sin(dLon / 2) * Math.sin(dLon / 2);

            Double c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
            return earthRadiusMeters * c;
        }

        private Double toRadians(Double degrees) {
            return degrees * Math.PI / 180.0;
        }
    }

    // ---------- Wrapper classes ----------

    public class TodayRecord {
        @AuraEnabled public String nextType;
        @AuraEnabled public String buttonLabel;
        @AuraEnabled public Boolean isDone;
        @AuraEnabled public String message;
        @AuraEnabled public Decimal lunchDurationMinutes;
        @AuraEnabled public Datetime nextOfficeCheckInOpensAt;
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
        @AuraEnabled public Datetime officeCheckInOpensAt;
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