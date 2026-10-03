import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTopDeductionsEmployees from '@salesforce/apex/AttendanceDeductionController.getTopDeductionsEmployees';
import hasHrPermission from '@salesforce/customPermission/Portal_HR_Access';
import getPaymentModes from '@salesforce/apex/AttendanceDeductionController.getPaymentModes';
import getPaymentHistory from '@salesforce/apex/AttendanceDeductionController.getPaymentHistory';
import redeemDeduction from '@salesforce/apex/AttendanceDeductionController.redeemDeduction';

const fmt = (n) => `₹${Number(n || 0).toFixed(2)}`;

export default class TopDeductions extends LightningElement {
    @track topEmployees = [];
    isLoading = true;
    hasError = false;
    errorMessage = '';
    wiredDeductionsResult;

    // modal state
    modalType = null; // 'redeem' | 'history' | null
    selected = null;
    amount = '';
    paymentDate = '';
    paymentMode = '';
    remarks = '';
    isSaving = false;
    modalError = '';
    isHistoryLoading = false;
    @track history = [];
    modeOptions = [];

    // true only if user's permission set includes "Portal HR Access"
    get isHr() {
        return hasHrPermission === true;
    }

    @wire(getPaymentModes)
    wiredModes({ data }) {
        if (data) {
            this.modeOptions = data.map((m) => ({ label: m, value: m }));
        }
    }

    @wire(getTopDeductionsEmployees)
    wiredDeductions(result) {
        this.wiredDeductionsResult = result;
        const { error, data } = result;
        this.isLoading = false;

        if (data) {
            this.hasError = false;
            this.errorMessage = '';

            // Highest pending deduction first, so rank #1 is always "The Unofficial CEO"
            const sorted = [...data].sort(
                (a, b) => Number(b.remainingAmount || 0) - Number(a.remainingAmount || 0)
            );

            this.topEmployees = sorted.map((item, index) => {
                const nameParts = item.employeeName ? item.employeeName.trim().split(' ') : ['E', 'M'];
                const initials =
                    nameParts.length >= 2
                        ? `${nameParts[0][0]}${nameParts[1][0]}`.toUpperCase()
                        : nameParts[0].substring(0, 2).toUpperCase();
                const paid = Number(item.paidAmount || 0);
                return {
                    employeeId: item.employeeId,
                    rank: index + 1,
                    employeeName: item.employeeName || 'Unknown Employee',
                    initials,
                    dateFormatted: item.attendanceSummaryDate || 'N/A',
                    remaining: Number(item.remainingAmount || 0),
                    deductionFormatted: fmt(item.remainingAmount),
                    grossFormatted: fmt(item.totalDeductionAmount),
                    paidFormatted: fmt(paid),
                    hasPaid: paid > 0,
                    officeLateDays: item.officeLateDays ?? 0,
                    lunchLateDays: item.lunchLateDays ?? 0
                };
            });
        } else if (error) {
            this.hasError = true;
            this.topEmployees = [];
            this.errorMessage = error.body ? error.body.message : 'Failed to load outstanding deductions.';
        }
    }

    get hasResults() {
        return !this.isLoading && !this.hasError && this.topEmployees.length > 0;
    }

    get isEmpty() {
        return !this.isLoading && !this.hasError && this.topEmployees.length === 0;
    }

    // Employee with the highest pending deduction = "The Unofficial CEO"
    get ceoEmployee() {
        return this.topEmployees.length > 0 ? this.topEmployees[0] : null;
    }

    get otherEmployees() {
        return this.topEmployees.slice(1);
    }

    get hasOtherEmployees() {
        return this.otherEmployees.length > 0;
    }

    // Header pill text
    get unsettledLabel() {
        const count = this.topEmployees.length;
        return count > 0 ? `${count} Unsettled` : 'All Unsettled';
    }

    /* ---------- Treat Header Summary Getters ---------- */
    get totalPoolFormatted() {
        const total = this.topEmployees.reduce(
            (sum, item) => sum + Number(item.remaining || 0),
            0
        );
        return fmt(total);
    }

    get topContributorName() {
        return this.ceoEmployee ? this.ceoEmployee.employeeName : 'None';
    }

    /* ---------- Modal Getters ---------- */
    get showModal() { return this.modalType !== null; }
    get isRedeemModal() { return this.modalType === 'redeem'; }
    get isHistoryModal() { return this.modalType === 'history'; }
    get modalTitle() {
        const n = this.selected ? this.selected.employeeName : '';
        return this.isRedeemModal ? `Redeem deduction — ${n}` : `Payment history — ${n}`;
    }
    get balanceFormatted() { return this.selected ? fmt(this.selected.remaining) : ''; }
    get balanceAfterFormatted() {
        const a = Number(this.amount);
        if (!this.selected || isNaN(a)) return this.balanceFormatted;
        return fmt(Math.max(this.selected.remaining - a, 0));
    }
    get todayStr() { return new Date().toISOString().slice(0, 10); }
    get hasHistory() { return !this.isHistoryLoading && this.history.length > 0; }
    get noHistory() { return !this.isHistoryLoading && this.history.length === 0; }
    get saveLabel() { return this.isSaving ? 'Saving...' : 'Confirm payment'; }

    /* ---------- Actions ---------- */
    handleRedeemClick(event) {
        this.selected = this.topEmployees.find((e) => e.employeeId === event.currentTarget.dataset.id);
        this.amount = this.selected.remaining; // full amount by default
        this.paymentDate = this.todayStr;
        this.paymentMode = '';
        this.remarks = '';
        this.modalError = '';
        this.modalType = 'redeem';
    }

    async handleHistoryClick(event) {
        this.selected = this.topEmployees.find((e) => e.employeeId === event.currentTarget.dataset.id);
        this.modalType = 'history';
        this.history = [];
        this.isHistoryLoading = true;
        try {
            const rows = await getPaymentHistory({ employeeId: this.selected.employeeId });
            this.history = rows.map((r) => ({
                id: r.id,
                amount: fmt(r.amount),
                paymentDate: r.paymentDate,
                recordedAt: r.recordedAt ? new Date(r.recordedAt).toLocaleString() : '',
                paymentMode: r.paymentMode || '—',
                remarks: r.remarks || '',
                balanceBefore: fmt(r.balanceBefore),
                balanceAfter: fmt(r.balanceAfter),
                recordedBy: r.recordedBy || ''
            }));
        } catch (e) {
            this.modalError = e.body ? e.body.message : 'Could not load history.';
        } finally {
            this.isHistoryLoading = false;
        }
    }

    handleCloseModal() {
        if (this.isSaving) return;
        this.modalType = null;
        this.selected = null;
        this.modalError = '';
    }

    handleAmountChange(e) { this.amount = e.target.value; }
    handleDateChange(e) { this.paymentDate = e.target.value; }
    handleModeChange(e) { this.paymentMode = e.detail.value; }
    handleRemarksChange(e) { this.remarks = e.target.value; }
    handlePayFull() { this.amount = this.selected.remaining; }

    async handleConfirm() {
        const a = Number(this.amount);
        if (!a || a <= 0) { 
            this.modalError = 'Enter an amount greater than 0.'; 
            return; 
        }
        if (a > this.selected.remaining) {
            this.modalError = `Amount cannot exceed ${this.balanceFormatted}.`;
            return;
        }
        if (!this.paymentDate) { 
            this.modalError = 'Select the payment date.'; 
            return; 
        }

        this.isSaving = true;
        this.modalError = '';
        try {
            const res = await redeemDeduction({
                employeeId: this.selected.employeeId,
                amount: a,
                paymentDate: this.paymentDate,
                paymentMode: this.paymentMode || null,
                remarks: this.remarks || null
            });
            const left = Number(res.balanceAfter);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Payment recorded',
                    message: left > 0 ? `${fmt(res.amount)} paid. ${fmt(left)} still pending.` : 'Fully settled. Deduction is now ₹0.00.',
                    variant: 'success'
                })
            );
            this.isSaving = false;
            this.handleCloseModal();
            await refreshApex(this.wiredDeductionsResult);
        } catch (e) {
            this.isSaving = false;
            this.modalError = e.body ? e.body.message : 'Payment failed.';
        }
    }

    handleRefresh() {
        this.isLoading = true;
        this.hasError = false;
        if (this.wiredDeductionsResult) {
            refreshApex(this.wiredDeductionsResult)
                .catch((error) => {
                    this.hasError = true;
                    this.errorMessage = 'Error refreshing data.';
                    console.error('Refresh Error:', error);
                })
                .finally(() => { this.isLoading = false; });
        } else {
            this.isLoading = false;
        }
    }
}