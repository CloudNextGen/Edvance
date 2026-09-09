import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getTopDeductionsEmployees from '@salesforce/apex/AttendanceDeductionController.getTopDeductionsEmployees';

export default class TopDeductions extends LightningElement {
    @track topEmployees = [];
    isLoading = true;
    hasError = false;
    errorMessage = '';

    wiredDeductionsResult;

    @wire(getTopDeductionsEmployees)
    wiredDeductions(result) {
        this.wiredDeductionsResult = result;
        const { error, data } = result;

        this.isLoading = false;

        if (data) {
            this.hasError = false;
            this.errorMessage = '';

            this.topEmployees = data.map((item, index) => {
                const rank = index + 1;
                
                // Get 2-letter initials
                const nameParts = item.employeeName ? item.employeeName.trim().split(' ') : ['E', 'M'];
                const initials = nameParts.length >= 2 
                    ? `${nameParts[0][0]}${nameParts[1][0]}`.toUpperCase()
                    : nameParts[0].substring(0, 2).toUpperCase();

                const formattedAmount = item.totalDeductionAmount !== undefined && item.totalDeductionAmount !== null
                    ? `₹${Number(item.totalDeductionAmount).toFixed(2)}`
                    : '₹0.00';

                return {
                    employeeId: item.employeeId,
                    rank: rank,
                    employeeName: item.employeeName || 'Unknown Employee',
                    initials: initials,
                    dateFormatted: item.attendanceSummaryDate || 'N/A',
                    deductionFormatted: formattedAmount,
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
        return !this.isLoading && !this.hasError && this.topEmployees && this.topEmployees.length > 0;
    }

    get isEmpty() {
        return !this.isLoading && !this.hasError && (!this.topEmployees || this.topEmployees.length === 0);
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
                .finally(() => {
                    this.isLoading = false;
                });
        } else {
            this.isLoading = false;
        }
    }
}