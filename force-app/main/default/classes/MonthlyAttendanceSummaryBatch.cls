public class MonthlyAttendanceSummaryBatch implements Database.Batchable<sObject>, Schedulable {

    // Schedulable: Runs daily at scheduled time, triggers batch only on the target last business day
    public void execute(SchedulableContext sc) {
        if (isLastWorkingDayOfMonth(Date.today())) {
            Database.executeBatch(new MonthlyAttendanceSummaryBatch(), 50);
        }
    }

    // Evaluates if date is the last valid business day:
    // If last calendar day is Saturday or Sunday, Friday is the trigger date.
    public static Boolean isLastWorkingDayOfMonth(Date d) {
        Date lastDayOfMonth = d.toStartOfMonth().addMonths(1).addDays(-1);

        Date targetDate = lastDayOfMonth;
        while (isWeekend(targetDate)) {
            targetDate = targetDate.addDays(-1); // Walks backwards to Friday
        }

        return (d == targetDate);
    }

    private static Boolean isWeekend(Date d) {
        DateTime dt = DateTime.newInstance(d, Time.newInstance(0, 0, 0, 0));
        String dayOfWeek = dt.format('E');
        return (dayOfWeek == 'Sat' || dayOfWeek == 'Sun');
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Name, Email, Manager__c, Manager__r.Name, Manager__r.Email
            FROM Contact
            WHERE Email != null
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Contact> contactList) {
        Date today = Date.today();
        Date monthStart = today.toStartOfMonth();
        Date monthEnd = today.toStartOfMonth().addMonths(1).addDays(-1);

        // Calculate expected working days: Total Mon-Sat minus 1 off Saturday
        Integer totalWorkingDays = calculateWorkingDays(monthStart, monthEnd);

        Set<Id> contactIds = new Map<Id, Contact>(contactList).keySet();

        List<Attendance_Summary__c> records = [
            SELECT Id, Date__c, Employee__c, 
                   Office_Late_Minutes__c, Lunch_Late_Minutes__c,
                   Office_Check_In_Time__c, Office_Check_Out_Time__c
            FROM Attendance_Summary__c
            WHERE Employee__c IN :contactIds
              AND Date__c >= :monthStart
              AND Date__c <= :monthEnd
        ];

        Set<Id> summaryIds = new Map<Id, Attendance_Summary__c>(records).keySet();
        Set<Id> officeExcusedSummaryIds = new Set<Id>();
        Set<Id> officeNotExcusedSummaryIds = new Set<Id>();
        Set<Id> lunchExcusedSummaryIds = new Set<Id>();
        Set<Id> lunchNotExcusedSummaryIds = new Set<Id>();
        for (Attendance_Log__c lateLog : [
            SELECT Attendance_Summary__c, Type__c, Status__c
            FROM Attendance_Log__c
            WHERE Attendance_Summary__c IN :summaryIds
              AND Is_Valid__c = true
              AND Late_Minutes__c > 0
              AND Type__c IN ('Office Check-In', 'Lunch Check-Out')
        ]) {
            if (lateLog.Type__c == 'Office Check-In') {
                if (lateLog.Status__c == 'Excused') {
                    officeExcusedSummaryIds.add(lateLog.Attendance_Summary__c);
                } else {
                    officeNotExcusedSummaryIds.add(lateLog.Attendance_Summary__c);
                }
            } else if (lateLog.Type__c == 'Lunch Check-Out') {
                if (lateLog.Status__c == 'Excused') {
                    lunchExcusedSummaryIds.add(lateLog.Attendance_Summary__c);
                } else {
                    lunchNotExcusedSummaryIds.add(lateLog.Attendance_Summary__c);
                }
            }
        }

        Map<Id, List<Attendance_Summary__c>> empAttendanceMap = new Map<Id, List<Attendance_Summary__c>>();
        for (Attendance_Summary__c att : records) {
            if (!empAttendanceMap.containsKey(att.Employee__c)) {
                empAttendanceMap.put(att.Employee__c, new List<Attendance_Summary__c>());
            }
            empAttendanceMap.get(att.Employee__c).add(att);
        }

        List<Messaging.SingleEmailMessage> emailsToSend = new List<Messaging.SingleEmailMessage>();

        for (Contact con : contactList) {
            List<Attendance_Summary__c> attList = empAttendanceMap.containsKey(con.Id) 
                ? empAttendanceMap.get(con.Id) 
                : new List<Attendance_Summary__c>();

            Integer daysAvailable = 0;
            Integer lateToOffice = 0;
            Integer excusedLateToOffice = 0;
            Integer extendedLunch = 0;
            Integer excusedExtendedLunch = 0;
            Integer halfDays = 0;

            for (Attendance_Summary__c att : attList) {
                if (att.Office_Check_In_Time__c != null) {
                    daysAvailable++;
                }

                if (att.Office_Late_Minutes__c != null && att.Office_Late_Minutes__c > 0) {
                    if (officeNotExcusedSummaryIds.contains(att.Id) || !officeExcusedSummaryIds.contains(att.Id)) {
                        lateToOffice++;
                    } else {
                        excusedLateToOffice++;
                    }
                }
                if (att.Lunch_Late_Minutes__c != null && att.Lunch_Late_Minutes__c > 0) {
                    if (lunchNotExcusedSummaryIds.contains(att.Id) || !lunchExcusedSummaryIds.contains(att.Id)) {
                        extendedLunch++;
                    } else {
                        excusedExtendedLunch++;
                    }
                }

                // Half day: worked between 4.0 and 6.5 hours
                if (att.Office_Check_In_Time__c != null && att.Office_Check_Out_Time__c != null) {
                    Long durationMillis = att.Office_Check_Out_Time__c.getTime() - att.Office_Check_In_Time__c.getTime();
                    Decimal hoursWorked = durationMillis / (1000.0 * 60.0 * 60.0);
                    if (hoursWorked >= 4.0 && hoursWorked < 6.5) {
                        halfDays++;
                    }
                }
            }

            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>{ con.Email });

            if (con.Manager__c != null && String.isNotBlank(con.Manager__r.Email)) {
                mail.setCcAddresses(new List<String>{ con.Manager__r.Email });
            }

            String monthName = DateTime.newInstance(today, Time.newInstance(0, 0, 0, 0)).format('MMMM yyyy');
            mail.setSubject('Employee Attendance Summary- ' + monthName);

            String managerDisplayName = (con.Manager__c != null && String.isNotBlank(con.Manager__r.Name)) 
                ? con.Manager__r.Name 
                : 'N/A';

            String htmlBody = buildHtmlTemplate(
                con.Name, 
                managerDisplayName,
                monthName,
                totalWorkingDays,
                daysAvailable,
                lateToOffice,
                excusedLateToOffice,
                halfDays,
                extendedLunch,
                excusedExtendedLunch
            );

            mail.setHtmlBody(htmlBody);
            emailsToSend.add(mail);
        }

        if (!emailsToSend.isEmpty()) {
            Messaging.sendEmail(emailsToSend, false);
        }
    }

    public void finish(Database.BatchableContext bc) {}

    // Calculation: (Total Mondays to Saturdays) - 1 Off Saturday
    private static Integer calculateWorkingDays(Date startDate, Date endDate) {
        Integer monToSatCount = 0;
        Date curr = startDate;
        while (curr <= endDate) {
            DateTime dt = DateTime.newInstance(curr, Time.newInstance(0, 0, 0, 0));
            if (dt.format('E') != 'Sun') {
                monToSatCount++;
            }
            curr = curr.addDays(1);
        }
        return Math.max(0, monToSatCount - 1);
    }

    private static String buildHtmlTemplate(
        String empName, String managerName, String monthYear,
        Integer totalDays, Integer daysPresent, Integer lateOffice, 
        Integer excusedLateOffice, Integer halfDays, Integer extLunch, Integer excusedExtLunch
    ) {
        return '<div style="font-family: Arial, sans-serif; max-width: 580px; border: 1px solid #1a1a1a;">'
            + '<div style="text-align: center; padding: 12px 10px 8px 10px; font-weight: bold;">'
            + '  <h3 style="margin: 0; font-size: 16px;">CloudNextGen IT Software Solutions LLP</h3>'
            + '  <h4 style="margin: 6px 0 0 0; font-size: 14px;">Employee Attendance Summary-' + monthYear + '</h4>'
            + '</div>'
            + '<table style="width: 100%; border-collapse: collapse; font-size: 13px;">'
            + '  <tr><td style="border: 1px solid #333; padding: 6px; font-weight: bold; width: 45%; color: #0d3c61;">Employee Name</td><td style="border: 1px solid #333; padding: 6px; font-weight: bold; color: #0d3c61;">' + empName + '</td></tr>'
            + '  <tr><td style="border: 1px solid #333; padding: 6px; font-weight: bold; color: #0d3c61;">Reporting Manager</td><td style="border: 1px solid #333; padding: 6px; font-weight: bold; color: #0d3c61;">' + managerName + '</td></tr>'
            + '  <tr><td colspan="2" style="background-color: #3b66af; color: white; text-align: center; font-weight: bold; padding: 6px;">Attendance Overview</td></tr>'
            + '  <tr><td style="border: 1px solid #333; padding: 6px; font-weight: bold; color: #0d3c61;">Total Working Days</td><td style="border: 1px solid #333; padding: 6px; text-align: right; font-weight: bold;">' + totalDays + '</td></tr>'
            + '  <tr><td style="border: 1px solid #333; padding: 6px; font-weight: bold; color: #0d3c61;">Days Availability</td><td style="border: 1px solid #333; padding: 6px; text-align: right; font-weight: bold;">' + daysPresent + '</td></tr>'
            + '  <tr><td style="border: 1px solid #333; padding: 6px; font-weight: bold; color: #0d3c61;">Office Late (Not Excused; includes pending appeals)</td><td style="border: 1px solid #333; padding: 6px; text-align: right; font-weight: bold;">' + lateOffice + '</td></tr>'
            + '  <tr><td style="border: 1px solid #333; padding: 6px; font-weight: bold; color: #0d3c61;">Office Late (Excused)</td><td style="border: 1px solid #333; padding: 6px; text-align: right; font-weight: bold;">' + excusedLateOffice + '</td></tr>'
            + '  <tr><td style="border: 1px solid #333; padding: 6px; font-weight: bold; color: #0d3c61;">Half Days</td><td style="border: 1px solid #333; padding: 6px; text-align: right; font-weight: bold;">' + halfDays + '</td></tr>'
            + '  <tr><td style="border: 1px solid #333; padding: 6px; font-weight: bold; color: #0d3c61;">Extended Lunch (Not Excused; includes pending appeals)</td><td style="border: 1px solid #333; padding: 6px; text-align: right; font-weight: bold;">' + extLunch + '</td></tr>'
            + '  <tr><td style="border: 1px solid #333; padding: 6px; font-weight: bold; color: #0d3c61;">Extended Lunch (Excused)</td><td style="border: 1px solid #333; padding: 6px; text-align: right; font-weight: bold;">' + excusedExtLunch + '</td></tr>'
            + '</table>'
            + '<p style="color: red; font-size: 11px; font-weight: bold; margin: 8px 6px;">Note- This summary is system-generated and shared before salary processing for transparency.</p>'
            + '</div>';
    }
}