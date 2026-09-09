import { LightningElement, api, track } from 'lwc';
import getPendingLateInstances from '@salesforce/apex/AttendanceAdminController.getPendingLateInstances';
import reviewLateInstance from '@salesforce/apex/AttendanceAdminController.reviewLateInstance';
import getHistory from '@salesforce/apex/AttendanceAdminController.getHistory';
import getDayDetail from '@salesforce/apex/AttendanceAdminController.getDayDetail';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class AttendanceAdminDetail extends LightningElement {
    @api contactId;
    @api employeeName;

    @track pendingList = [];
    @track historyRows = [];
    @track dayEvents = [];

    // KPI Summary Metrics
    @track totalLateCount = 0;
    @track totalDeductionAmount = 0;

    isLoadingAppeals = true;
    isLoadingHistory = true;
    isLoadingDay = false;

    fromDate;
    toDate;
    lateOnly = false;

    view = 'list'; // 'list' | 'dayDetail'
    selectedDayLabel = '';
    selectedSummaryId;

    showLightbox = false;
    lightboxUrl;

    historyPageNumber = 0;
    historyTotalCount = 0;

    connectedCallback() {
        const today = new Date();
        const past = new Date();
        past.setDate(today.getDate() - 30);
        this.toDate = this.formatDateInput(today);
        this.fromDate = this.formatDateInput(past);

        this.loadAppeals();
        this.loadHistory();
    }

    formatDateInput(d) {
        const yyyy = d.getFullYear();
        const mm = String(d.getMonth() + 1).padStart(2, '0');
        const dd = String(d.getDate()).padStart(2, '0');
        return `${yyyy}-${mm}-${dd}`;
    }

    get showListView() {
        return this.view === 'list';
    }

    get showDayDetailView() {
        return this.view === 'dayDetail';
    }

    get hasNoAppeals() {
        return !this.isLoadingAppeals && this.pendingList.length === 0;
    }

    get hasNoHistory() {
        return !this.isLoadingHistory && this.historyRows.length === 0;
    }
    
    loadAppeals() {
        this.isLoadingAppeals = true;
        getPendingLateInstances({ employeeId: this.contactId })
            .then((data) => {
                this.pendingList = data.map((rec) => ({
                    id: rec.Id,
                    type: rec.Type__c,
                    date: rec.Attendance_Summary__r ? rec.Attendance_Summary__r.Date__c : '',
                    lateMinutes: rec.Late_Minutes__c,
                    reason: rec.Excusal_Reason__c || 'No reason provided',
                    deduction: rec.Deduction_Amount__c
                }));
            })
            .catch(() => this.showToast('Error', 'Could not load pending appeals.', 'error'))
            .finally(() => { this.isLoadingAppeals = false; });
    }

    loadHistory() {
        this.isLoadingHistory = true;
        getHistory({
            employeeId: this.contactId,
            startDate: this.fromDate,
            endDate: this.toDate,
            lateOnly: this.lateOnly,
            pageNumber: this.historyPageNumber
        })
            .then((result) => {
                this.historyTotalCount = result.totalCount;
                this.historyRows = result.records.map((row) => this.mapHistoryRow(row));
                
                this.totalLateCount = result.records.filter(row => 
                    (row.Office_Late_Minutes__c && row.Office_Late_Minutes__c > 0) || 
                    (row.Lunch_Late_Minutes__c && row.Lunch_Late_Minutes__c > 0)
                ).length;

                this.totalDeductionAmount = result.records.reduce((sum, row) => sum + (row.Total_Deduction_Amount__c || 0), 0);
            })
            .catch(() => this.showToast('Error', 'Could not load history.', 'error'))
            .finally(() => { this.isLoadingHistory = false; });
    }

    handleApply() {
        this.historyPageNumber = 0;
        this.loadHistory();
    }

    handleHistoryPrevPage() {
        if (this.historyPageNumber > 0) {
            this.historyPageNumber -= 1;
            this.loadHistory();
        }
    }

    handleHistoryNextPage() {
        if ((this.historyPageNumber + 1) * 10 < this.historyTotalCount) {
            this.historyPageNumber += 1;
            this.loadHistory();
        }
    }

    get historyTotalPages() {
        return Math.max(1, Math.ceil(this.historyTotalCount / 10));
    }
    get historyPageLabel() {
        return `Page ${this.historyPageNumber + 1} of ${this.historyTotalPages}`;
    }
    get isFirstHistoryPage() {
        return this.historyPageNumber === 0;
    }
    get noMoreHistoryPages() {
        return (this.historyPageNumber + 1) * 10 >= this.historyTotalCount;
    }

    formatLateMinutes(minutes) {
        if (!minutes || minutes <= 0) return '0 min';
        if (minutes < 60) return `${minutes} min`;
        const hours = Math.floor(minutes / 60);
        const mins = minutes % 60;
        return mins > 0 ? `${hours}h ${mins}m` : `${hours}h`;
    }

    mapHistoryRow(row) {
        const statuses = (row.Attendance_Logs__r || []).map((l) => l.Status__c);
        let statusLabel = 'On time';
        let statusClass = 'status-chip status-ontime';
        if (statuses.includes('Not Excused')) {
            statusLabel = 'Deduction applied';
            statusClass = 'status-chip status-deducted';
        } else if (statuses.includes('Excused')) {
            statusLabel = 'Excused';
            statusClass = 'status-chip status-excused';
        } else if (statuses.includes('Pending')) {
            statusLabel = 'Late — pending review';
            statusClass = 'status-chip status-pending';
        }

        return {
            id: row.Id,
            dateLabel: row.Date__c,
            officeIn: this.formatTime(row.Office_Check_In_Time__c),
            officeOut: this.formatTime(row.Office_Check_Out_Time__c),
            lunchOut: this.formatTime(row.Lunch_Out_Time__c),
            lunchIn: this.formatTime(row.Lunch_In_Time__c),
            officeLateMinutes: this.formatLateMinutes(row.Office_Late_Minutes__c || 0),
            lunchLateMinutes: this.formatLateMinutes(row.Lunch_Late_Minutes__c || 0),
            deduction: row.Total_Deduction_Amount__c || 0,
            statusLabel,
            statusClass
        };
    }

    formatTime(dt) {
        if (!dt) return '—';
        const d = new Date(dt);
        return d.toLocaleTimeString('en-IN', {
            timeZone: 'Asia/Kolkata',
            hour: '2-digit',
            minute: '2-digit',
            hour12: true
        });
    }

    handleFromChange(event) {
        this.fromDate = event.target.value;
    }
    handleToChange(event) {
        this.toDate = event.target.value;
    }
    handleLateOnlyChange(event) {
        this.lateOnly = event.target.checked;
    }

    // Export current loaded rows to CSV spreadsheet format
    handleExport() {
        if (!this.historyRows || this.historyRows.length === 0) {
            this.showToast('Warning', 'No history records available to export.', 'warning');
            return;
        }

        const headers = ['Date', 'Office In', 'Office Out', 'Lunch Out', 'Lunch In', 'Office Late', 'Lunch Late', 'Deduction', 'Status'];
        const csvRows = [headers.join(',')];

        this.historyRows.forEach(row => {
            const values = [
                `"${row.dateLabel || ''}"`,
                `"${row.officeIn || ''}"`,
                `"${row.officeOut || ''}"`,
                `"${row.lunchOut || ''}"`,
                `"${row.lunchIn || ''}"`,
                `"${row.officeLateMinutes || ''}"`,
                `"${row.lunchLateMinutes || ''}"`,
                `"${row.deduction || 0}"`,
                `"${row.statusLabel || ''}"`
            ];
            csvRows.push(values.join(','));
        });

        const csvContent = 'data:text/csv;charset=utf-8,' + csvRows.join('\n');
        const encodedUri = encodeURI(csvContent);
        const link = document.createElement('a');
        link.setAttribute('href', encodedUri);
        link.setAttribute('download', `Attendance_${this.employeeName || 'Report'}.csv`);
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
    }

    async handleDecision(event) {
        const logId = event.target.dataset.id;
        const approve = event.target.dataset.approve === 'true';

        this.pendingList = this.pendingList.filter((item) => item.id !== logId);

        try {
            await reviewLateInstance({ logId, approve });
            this.showToast('Success', approve ? 'Appeal approved.' : 'Appeal rejected.', 'success');
            this.loadHistory();
            if (this.view === 'dayDetail' && this.selectedSummaryId) {
                this.loadDayDetail(this.selectedSummaryId);
            }
        } catch (e) {
            this.showToast('Error', 'Could not save decision. Please try again.', 'error');
            this.loadAppeals();
        }
    }

    handleRowClick(event) {
        const summaryId = event.currentTarget.dataset.id;
        const row = this.historyRows.find((r) => r.id === summaryId);
        this.selectedSummaryId = summaryId;
        this.selectedDayLabel = row ? row.dateLabel : '';
        this.view = 'dayDetail';
        this.loadDayDetail(summaryId);
    }

    loadDayDetail(summaryId) {
        this.isLoadingDay = true;
        getDayDetail({ summaryId })
            .then((data) => {
                this.dayEvents = data.map((ev) => ({
                    logId: ev.logId,
                    type: ev.type,
                    timeLabel: this.formatTime(ev.eventTimestamp),
                    status: ev.status,
                    excusalReason: ev.excusalReason,
                    photoUrl: ev.photoUrl
                }));
            })
            .catch(() => this.showToast('Error', 'Could not load day detail.', 'error'))
            .finally(() => { this.isLoadingDay = false; });
    }

    handleBackFromDay() {
        this.view = 'list';
        this.dayEvents = [];
    }

    handlePhotoClick(event) {
        this.lightboxUrl = event.currentTarget.dataset.url;
        this.showLightbox = true;
    }
    closeLightbox() {
        this.showLightbox = false;
        this.lightboxUrl = undefined;
    }

    handleBack() {
        this.dispatchEvent(new CustomEvent('back'));
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}