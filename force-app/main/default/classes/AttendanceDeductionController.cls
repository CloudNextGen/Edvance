// without sharing: this widget shows ORG-WIDE totals. With 'with sharing', every user only
// sums the records they can see (admin sees all, community user sees a subset) -> different amounts.
// Writes/history are still protected by assertHr() (custom permission Portal_HR_Access).
public without sharing class AttendanceDeductionController {

    public class DeductionSummaryWrapper {
        @AuraEnabled public String employeeId { get; set; }
        @AuraEnabled public String employeeName { get; set; }
        @AuraEnabled public Decimal totalDeductionAmount { get; set; } // gross (this month)
        @AuraEnabled public Decimal paidAmount { get; set; }           // redeemed so far (this month)
        @AuraEnabled public Decimal remainingAmount { get; set; }      // gross - paid
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

    /* ------------------------------------------------------------------ */
    /*  HR gate: custom permission "Portal_HR_Access"             */
    /* ------------------------------------------------------------------ */
    @AuraEnabled(cacheable=true)
    public static Boolean canManageDeductions() {
        return FeatureManagement.checkPermission('Portal_HR_Access');
    }

    private static void assertHr() {
        if (!canManageDeductions()) {
            throw new AuraHandledException('Only HR can perform this action.');
        }
    }

    /* ------------------------------------------------------------------ */
    /*  READ: top 3 employees by REMAINING deduction (this month)          */
    /* ------------------------------------------------------------------ */
    @AuraEnabled(cacheable=true)
    public static List<DeductionSummaryWrapper> getTopDeductionsEmployees() {
        List<DeductionSummaryWrapper> resultList = new List<DeductionSummaryWrapper>();

        try {
            // 1) Gross deduction per employee (no LIMIT: ranking must be on NET amount)
            Map<Id, DeductionSummaryWrapper> byEmp = new Map<Id, DeductionSummaryWrapper>();
            for (AggregateResult ar : [
                SELECT Employee__c empId,
                       SUM(Total_Deduction_Amount__c) totalDeduction,
                       SUM(Office_Late_Minutes__c) totalOfficeLate,
                       SUM(Lunch_Late_Minutes__c) totalLunchLate
                FROM Attendance_Summary__c
                WHERE Total_Deduction_Amount__c > 0
                AND Date__c = THIS_MONTH
                AND Employee__c != null
                WITH SYSTEM_MODE
                GROUP BY Employee__c
            ]) {
                Id empId = (Id) ar.get('empId');
                DeductionSummaryWrapper w = new DeductionSummaryWrapper();
                w.employeeId = empId;
                w.totalDeductionAmount = (Decimal) ar.get('totalDeduction');
                w.offLateMinutes = (Decimal) ar.get('totalOfficeLate');
                w.lunchLateMinutes = (Decimal) ar.get('totalLunchLate');
                w.paidAmount = 0;
                byEmp.put(empId, w);
            }

            if (byEmp.isEmpty()) return resultList;

            // 2) Payments already made against this month
            for (AggregateResult ar : [
                SELECT Employee__c empId, SUM(Amount__c) paid
                FROM Deduction_Payment__c
                WHERE Employee__c IN :byEmp.keySet()
                AND Applied_Month__c = THIS_MONTH
                WITH SYSTEM_MODE
                GROUP BY Employee__c
            ]) {
                DeductionSummaryWrapper w = byEmp.get((Id) ar.get('empId'));
                if (w != null && ar.get('paid') != null) w.paidAmount = (Decimal) ar.get('paid');
            }

            // 3) Remaining = gross - paid; keep only > 0; rank desc; top 3
            List<DeductionSummaryWrapper> pending = new List<DeductionSummaryWrapper>();
            for (DeductionSummaryWrapper w : byEmp.values()) {
                w.remainingAmount = w.totalDeductionAmount - w.paidAmount;
                if (w.remainingAmount > 0) pending.add(w);
            }
            pending.sort(new RemainingDescComparator());
            for (Integer i = 0; i < pending.size() && i < 3; i++) resultList.add(pending[i]);

            if (resultList.isEmpty()) return resultList;

            Set<Id> empIds = new Set<Id>();
            for (DeductionSummaryWrapper w : resultList) empIds.add((Id) w.employeeId);

            // 4) Names
            Map<Id, String> employeeNameMap = new Map<Id, String>();
            for (Contact c : [SELECT Id, Name FROM Contact WHERE Id IN :empIds WITH SYSTEM_MODE]) {
                employeeNameMap.put(c.Id, c.Name);
            }

            // 5) Late day counts (both limited to THIS_MONTH)
            Map<Id, Integer> officeLateDaysMap = new Map<Id, Integer>();
            Map<Id, Integer> lunchLateDaysMap = new Map<Id, Integer>();
            for (AggregateResult a : [
                SELECT Employee__c empId, COUNT(Id) totalDays
                FROM Attendance_Summary__c
                WHERE Employee__c IN :empIds AND Office_Late_Minutes__c > 0
                AND Date__c = THIS_MONTH
                WITH SYSTEM_MODE
                GROUP BY Employee__c
            ]) {
                officeLateDaysMap.put((Id) a.get('empId'), (Integer) a.get('totalDays'));
            }
            for (AggregateResult a : [
                SELECT Employee__c empId, COUNT(Id) totalDays
                FROM Attendance_Summary__c
                WHERE Employee__c IN :empIds AND Lunch_Late_Minutes__c > 0
                AND Date__c = THIS_MONTH
                WITH SYSTEM_MODE
                GROUP BY Employee__c
            ]) {
                lunchLateDaysMap.put((Id) a.get('empId'), (Integer) a.get('totalDays'));
            }

            // 6) Latest summary record
            Map<Id, Attendance_Summary__c> latestRecordMap = new Map<Id, Attendance_Summary__c>();
            for (Attendance_Summary__c rec : [
                SELECT Id, Employee__c, Date__c
                FROM Attendance_Summary__c
                WHERE Employee__c IN :empIds
                AND Date__c = THIS_MONTH
                WITH SYSTEM_MODE
                ORDER BY Date__c DESC
            ]) {
                if (!latestRecordMap.containsKey(rec.Employee__c)) latestRecordMap.put(rec.Employee__c, rec);
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
    /*  WRITE: redeem (full or partial) -> creates a payment record        */
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

            // Re-check balance on the server (never trust the amount shown in the UI)
            Decimal gross = 0;
            for (AggregateResult ar : [
                SELECT SUM(Total_Deduction_Amount__c) t
                FROM Attendance_Summary__c
                WHERE Employee__c = :employeeId AND Total_Deduction_Amount__c > 0
                AND Date__c = THIS_MONTH
                WITH SYSTEM_MODE
            ]) {
                if (ar.get('t') != null) gross = (Decimal) ar.get('t');
            }
            Decimal paid = 0;
            for (AggregateResult ar : [
                SELECT SUM(Amount__c) p
                FROM Deduction_Payment__c
                WHERE Employee__c = :employeeId AND Applied_Month__c = THIS_MONTH
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
    /*  READ: payment history for one employee (this month)                */
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
                WHERE Employee__c = :employeeId AND Applied_Month__c = THIS_MONTH
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