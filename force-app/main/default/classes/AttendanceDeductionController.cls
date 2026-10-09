// without sharing: this widget shows ORG-WIDE totals. With 'with sharing', every user only
// sums the records they can see (admin sees all, community user sees a subset) -> different amounts.
// Writes/history are still protected by assertHr() (custom permission Portal_HR_Access).
public without sharing class AttendanceDeductionController {
    @TestVisible private static Boolean excludeSaturdayOverride;

    public class DeductionSummaryWrapper {
        @AuraEnabled public String employeeId { get; set; }
        @AuraEnabled public String employeeName { get; set; }
        @AuraEnabled public Decimal totalDeductionAmount { get; set; } // gross incurred in filtered period
        @AuraEnabled public Decimal paidAmount { get; set; }           // paid portion applied to this period
        @AuraEnabled public Decimal remainingAmount { get; set; }      // pending in this period
        @AuraEnabled public Decimal offLateMinutes { get; set; }
        @AuraEnabled public Decimal lunchLateMinutes { get; set; }
        @AuraEnabled public Integer officeLateDays { get; set; }
        @AuraEnabled public Integer lunchLateDays { get; set; }
        @AuraEnabled public String attendanceSummaryId { get; set; }
        @AuraEnabled public String attendanceSummaryDate { get; set; }
    }

    public class PaymentWrapper {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String paymentDate { get; set; }
        @AuraEnabled public Datetime recordedAt { get; set; }
        @AuraEnabled public String paymentMode { get; set; }
        @AuraEnabled public String remarks { get; set; }
        @AuraEnabled public Decimal balanceBefore { get; set; }
        @AuraEnabled public Decimal balanceAfter { get; set; }
        @AuraEnabled public String recordedBy { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static Boolean canManageDeductions() {
        return FeatureManagement.checkPermission('Portal_HR_Access');
    }

    private static void assertHr() {
        if (!canManageDeductions()) {
            throw new AuraHandledException('Only HR can perform this action.');
        }
    }

    private static Boolean getExcludeSaturdaySetting() {
        if (excludeSaturdayOverride != null) {
            return excludeSaturdayOverride;
        }
        List<Assessment_Portal_Config__mdt> configs = [
            SELECT Exclude_Saturday__c
            FROM Assessment_Portal_Config__mdt
            LIMIT 1
        ];
        return !configs.isEmpty() && configs[0].Exclude_Saturday__c == true;
    }

    /* ------------------------------------------------------------------ */
    /*  READ: employees by REMAINING deduction with FIFO reconciliation   */
    /* ------------------------------------------------------------------ */
    @AuraEnabled(cacheable=true)
    public static List<DeductionSummaryWrapper> getTopDeductionsEmployees(Date startDate, Date endDate) {
        List<DeductionSummaryWrapper> resultList = new List<DeductionSummaryWrapper>();

        try {
            Date validStart = startDate;
            Date validEnd = endDate;
            if (validStart != null && validEnd != null && validStart > validEnd) {
                Date temp = validStart;
                validStart = validEnd;
                validEnd = temp;
            }

            // Saturday Filter Clause
            String saturdayFilter = getExcludeSaturdaySetting()
                ? ' AND DAY_IN_WEEK(Date__c) != 7 '
                : '';

            // Date condition for Attendance Summary records in this window
            String attDateFilter = '';
            if (validStart != null) {
                attDateFilter += ' AND Date__c >= :validStart ';
            }
            if (validEnd != null) {
                attDateFilter += ' AND Date__c <= :validEnd ';
            }

            // 1) Gross deductions & late minutes incurred strictly within the selected window
            String grossQuery = 
                'SELECT Employee__c empId, ' +
                '       SUM(Total_Deduction_Amount__c) totalDeduction, ' +
                '       SUM(Office_Late_Minutes__c) totalOfficeLate, ' +
                '       SUM(Lunch_Late_Minutes__c) totalLunchLate ' +
                'FROM Attendance_Summary__c ' +
                'WHERE Total_Deduction_Amount__c > 0 ' +
                'AND Employee__c != null ' +
                attDateFilter +
                saturdayFilter +
                'WITH SYSTEM_MODE ' +
                'GROUP BY Employee__c';

            Map<Id, DeductionSummaryWrapper> byEmp = new Map<Id, DeductionSummaryWrapper>();
            for (AggregateResult ar : (List<AggregateResult>) Database.query(grossQuery)) {
                Id empId = (Id) ar.get('empId');
                DeductionSummaryWrapper w = new DeductionSummaryWrapper();
                w.employeeId = empId;
                w.totalDeductionAmount = (Decimal) ar.get('totalDeduction');
                w.offLateMinutes = (Decimal) ar.get('totalOfficeLate');
                w.lunchLateMinutes = (Decimal) ar.get('totalLunchLate');
                w.paidAmount = 0;
                w.remainingAmount = 0;
                byEmp.put(empId, w);
            }

            if (byEmp.isEmpty()) return resultList;

            Set<Id> candidateEmpIds = byEmp.keySet();

            // 2) Total all-time gross deductions for these candidates (honoring saturday config)
            Map<Id, Decimal> allTimeGrossMap = new Map<Id, Decimal>();
            String allTimeGrossQuery = 
                'SELECT Employee__c empId, SUM(Total_Deduction_Amount__c) totalGross ' +
                'FROM Attendance_Summary__c ' +
                'WHERE Employee__c IN :candidateEmpIds AND Total_Deduction_Amount__c > 0 ' +
                saturdayFilter +
                'WITH SYSTEM_MODE ' +
                'GROUP BY Employee__c';

            for (AggregateResult ar : (List<AggregateResult>) Database.query(allTimeGrossQuery)) {
                allTimeGrossMap.put((Id) ar.get('empId'), (Decimal) ar.get('totalGross'));
            }

            // 3) Total all-time payments made by these candidates
            Map<Id, Decimal> allTimePaidMap = new Map<Id, Decimal>();
            for (AggregateResult ar : [
                SELECT Employee__c empId, SUM(Amount__c) totalPaid
                FROM Deduction_Payment__c
                WHERE Employee__c IN :candidateEmpIds
                WITH SYSTEM_MODE
                GROUP BY Employee__c
            ]) {
                allTimePaidMap.put((Id) ar.get('empId'), (Decimal) ar.get('totalPaid'));
            }

            // 4) Prior gross debt incurred BEFORE validStart (to absorb payments chronologically)
            Map<Id, Decimal> priorGrossMap = new Map<Id, Decimal>();
            if (validStart != null) {
                String priorQuery = 
                    'SELECT Employee__c empId, SUM(Total_Deduction_Amount__c) priorGross ' +
                    'FROM Attendance_Summary__c ' +
                    'WHERE Employee__c IN :candidateEmpIds ' +
                    'AND Total_Deduction_Amount__c > 0 ' +
                    'AND Date__c < :validStart ' +
                    saturdayFilter +
                    'WITH SYSTEM_MODE ' +
                    'GROUP BY Employee__c';

                for (AggregateResult ar : (List<AggregateResult>) Database.query(priorQuery)) {
                    priorGrossMap.put((Id) ar.get('empId'), (Decimal) ar.get('priorGross'));
                }
            }

            // 5) FIFO Reconciliation
            List<DeductionSummaryWrapper> pending = new List<DeductionSummaryWrapper>();
            for (DeductionSummaryWrapper w : byEmp.values()) {
                Id empId = (Id) w.employeeId;
                Decimal grossAllTime = allTimeGrossMap.containsKey(empId) ? allTimeGrossMap.get(empId) : 0;
                Decimal totalPaid    = allTimePaidMap.containsKey(empId) ? allTimePaidMap.get(empId) : 0;
                Decimal priorGross   = priorGrossMap.containsKey(empId) ? priorGrossMap.get(empId) : 0;

                // What payment remains after clearing debts older than validStart
                Decimal remainingPaidForWindow = Math.max(0, totalPaid - priorGross);

                // What is still unpaid in this window
                Decimal windowRemaining = Math.max(0, w.totalDeductionAmount - remainingPaidForWindow);

                // Guardrail: Can never exceed total all-time debt
                Decimal trueRemainingOverall = Math.max(0, grossAllTime - totalPaid);

                w.remainingAmount = Math.min(windowRemaining, trueRemainingOverall);
                w.paidAmount = Math.max(0, w.totalDeductionAmount - w.remainingAmount);

                // Only show active outstanding debt on the leaderboard
                if (w.remainingAmount > 0) {
                    pending.add(w);
                }
            }

            if (pending.isEmpty()) return resultList;

            pending.sort(new RemainingDescComparator());
            resultList.addAll(pending);

            Set<Id> empIds = new Set<Id>();
            for (DeductionSummaryWrapper w : resultList) {
                empIds.add((Id) w.employeeId);
            }

            // 6) Contact Names
            Map<Id, String> employeeNameMap = new Map<Id, String>();
            for (Contact c : [SELECT Id, Name FROM Contact WHERE Id IN :empIds WITH SYSTEM_MODE]) {
                employeeNameMap.put(c.Id, c.Name);
            }

            // 7) Late Days counts within the filtered window
            String offLateQuery = 
                'SELECT Employee__c empId, COUNT(Id) totalDays ' +
                'FROM Attendance_Summary__c ' +
                'WHERE Employee__c IN :empIds AND Office_Late_Minutes__c > 0 ' +
                attDateFilter +
                saturdayFilter +
                'WITH SYSTEM_MODE ' +
                'GROUP BY Employee__c';

            String lunchLateQuery = 
                'SELECT Employee__c empId, COUNT(Id) totalDays ' +
                'FROM Attendance_Summary__c ' +
                'WHERE Employee__c IN :empIds AND Lunch_Late_Minutes__c > 0 ' +
                attDateFilter +
                saturdayFilter +
                'WITH SYSTEM_MODE ' +
                'GROUP BY Employee__c';

            Map<Id, Integer> officeLateDaysMap = new Map<Id, Integer>();
            Map<Id, Integer> lunchLateDaysMap = new Map<Id, Integer>();

            for (AggregateResult a : (List<AggregateResult>) Database.query(offLateQuery)) {
                officeLateDaysMap.put((Id) a.get('empId'), (Integer) a.get('totalDays'));
            }
            for (AggregateResult a : (List<AggregateResult>) Database.query(lunchLateQuery)) {
                lunchLateDaysMap.put((Id) a.get('empId'), (Integer) a.get('totalDays'));
            }

            // 8) Latest summary date within the filtered window
            String latestRecQuery = 
                'SELECT Id, Employee__c, Date__c ' +
                'FROM Attendance_Summary__c ' +
                'WHERE Employee__c IN :empIds ' +
                attDateFilter +
                saturdayFilter +
                'WITH SYSTEM_MODE ' +
                'ORDER BY Date__c DESC';

            Map<Id, Attendance_Summary__c> latestRecordMap = new Map<Id, Attendance_Summary__c>();
            for (Attendance_Summary__c rec : (List<Attendance_Summary__c>) Database.query(latestRecQuery)) {
                if (!latestRecordMap.containsKey(rec.Employee__c)) {
                    latestRecordMap.put(rec.Employee__c, rec);
                }
            }

            for (DeductionSummaryWrapper w : resultList) {
                Id empId = (Id) w.employeeId;
                w.employeeName = employeeNameMap.containsKey(empId) ? employeeNameMap.get(empId) : 'Employee Record';
                w.officeLateDays = officeLateDaysMap.containsKey(empId) ? officeLateDaysMap.get(empId) : 0;
                w.lunchLateDays = lunchLateDaysMap.containsKey(empId) ? lunchLateDaysMap.get(empId) : 0;
                Attendance_Summary__c latest = latestRecordMap.get(empId);
                if (latest != null) {
                    w.attendanceSummaryId = latest.Id;
                    w.attendanceSummaryDate = latest.Date__c != null ? String.valueOf(latest.Date__c) : '';
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AttendanceDeductionController.getTopDeductionsEmployees failed: ' + e.getMessage());
            throw new AuraHandledException(e.getMessage());
        }

        return resultList;
    }

    /* ------------------------------------------------------------------ */
    /*  WRITE: redeem                                                     */
    /* ------------------------------------------------------------------ */
    @AuraEnabled
    public static PaymentWrapper redeemDeduction(Id employeeId, Decimal amount, Date paymentDate,
                                                 String paymentMode, String remarks) {
        try {
            assertHr();
            if (employeeId == null) throw new AuraHandledException('Employee is required.');
            if (amount == null || amount <= 0) throw new AuraHandledException('Enter an amount greater than 0.');
            Date payDate = paymentDate != null ? paymentDate : Date.today();
            if (payDate > Date.today()) throw new AuraHandledException('Payment date cannot be in the future.');

            String saturdayFilter = getExcludeSaturdaySetting()
                ? ' AND DAY_IN_WEEK(Date__c) != 7 '
                : '';

            Decimal gross = 0;
            for (AggregateResult ar : Database.query(
                'SELECT SUM(Total_Deduction_Amount__c) t FROM Attendance_Summary__c ' +
                'WHERE Employee__c = :employeeId AND Total_Deduction_Amount__c > 0 ' +
                saturdayFilter + 'WITH SYSTEM_MODE'
            )) {
                if (ar.get('t') != null) gross = (Decimal) ar.get('t');
            }
            Decimal paid = 0;
            for (AggregateResult ar : [
                SELECT SUM(Amount__c) p
                FROM Deduction_Payment__c
                WHERE Employee__c = :employeeId
                WITH SYSTEM_MODE
            ]) {
                if (ar.get('p') != null) paid = (Decimal) ar.get('p');
            }
            Decimal balanceBefore = gross - paid;

            if (balanceBefore <= 0) throw new AuraHandledException('No outstanding deduction for this employee.');
            if (amount > balanceBefore) {
                throw new AuraHandledException('Amount exceeds outstanding balance of ₹' + balanceBefore.setScale(2) + '.');
            }

            Deduction_Payment__c p = new Deduction_Payment__c(
                Employee__c = employeeId,
                Amount__c = amount.setScale(2),
                Payment_Date__c = payDate,
                Applied_Month__c = Date.today().toStartOfMonth(),
                Payment_Mode__c = paymentMode,
                Remark__c = remarks,
                Balance_Before__c = balanceBefore,
                Balance_After__c = balanceBefore - amount,
                Recorded_By__c = UserInfo.getUserId()
            );
            insert p;

            return toWrapper([
                SELECT Id, Amount__c, Payment_Date__c, CreatedDate, Payment_Mode__c, Remark__c,
                       Balance_Before__c, Balance_After__c, Recorded_By__r.Name
                FROM Deduction_Payment__c WHERE Id = :p.Id WITH SYSTEM_MODE
            ][0]);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AttendanceDeductionController.redeemDeduction failed: ' + e.getMessage());
            throw new AuraHandledException(e.getMessage());
        }
    }

    /* ------------------------------------------------------------------ */
    /*  READ: payment history                                             */
    /* ------------------------------------------------------------------ */
    @AuraEnabled
    public static List<PaymentWrapper> getPaymentHistory(Id employeeId) {
        List<PaymentWrapper> out = new List<PaymentWrapper>();
        try {
            assertHr();
            for (Deduction_Payment__c p : [
                SELECT Id, Amount__c, Payment_Date__c, CreatedDate, Payment_Mode__c, Remark__c,
                       Balance_Before__c, Balance_After__c, Recorded_By__r.Name
                FROM Deduction_Payment__c
                WHERE Employee__c = :employeeId
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC
            ]) {
                out.add(toWrapper(p));
            }
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getPaymentModes() {
        List<String> modes = new List<String>();
        for (Schema.PicklistEntry pe : Deduction_Payment__c.Payment_Mode__c.getDescribe().getPicklistValues()) {
            if (pe.isActive()) modes.add(pe.getValue());
        }
        return modes;
    }

    private static PaymentWrapper toWrapper(Deduction_Payment__c p) {
        PaymentWrapper w = new PaymentWrapper();
        w.id = p.Id;
        w.amount = p.Amount__c;
        w.paymentDate = p.Payment_Date__c != null ? String.valueOf(p.Payment_Date__c) : '';
        w.recordedAt = p.CreatedDate;
        w.paymentMode = p.Payment_Mode__c;
        w.remarks = p.Remark__c;
        w.balanceBefore = p.Balance_Before__c;
        w.balanceAfter = p.Balance_After__c;
        w.recordedBy = p.Recorded_By__r != null ? p.Recorded_By__r.Name : null;
        return w;
    }

    public class RemainingDescComparator implements System.Comparator<DeductionSummaryWrapper> {
        public Integer compare(DeductionSummaryWrapper a, DeductionSummaryWrapper b) {
            if (a.remainingAmount == b.remainingAmount) return 0;
            return a.remainingAmount < b.remainingAmount ? 1 : -1;
        }
    }
}