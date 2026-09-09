import { LightningElement, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getQueueRequests from '@salesforce/apex/PortalRequestService.getQueueRequests';
import saveRequestAndComment from '@salesforce/apex/PortalRequestService.saveRequestAndComment';

const STATUS_LABEL = {
    New: 'Not Started',
    Working: 'In Progress',
    Closed: 'Completed'
};

const STATUS_BADGE_CLASS = {
    New: 'badge badge_info',
    Working: 'badge badge_warning',
    Closed: 'badge badge_success'
};

const STATUS_ROW_CLASS = {
    New: 'request-row request-row_open',
    Working: 'request-row request-row_progress',
    Closed: 'request-row request-row_completed'
};

const STATUS_OPTIONS = [
    { label: 'Not Started', value: 'New' },
    { label: 'In Progress', value: 'Working' },
    { label: 'Completed', value: 'Closed' }
];

export default class AdminRequests extends LightningElement {
    @track wiredResult;
    @track errorMessage = '';
    @track isModalOpen = false;
    @track isSubmitting = false;
    @track isRefreshing = false;
    @track formError = '';
    @track selectedCaseId = null;
    @track selectedRequester = '';
    @track selectedSubject = '';
    @track selectedDescription = '';
    @track selectedStatus = '';
    originalStatus = '';
    @track statusOptions = STATUS_OPTIONS;
    @track selectedFilter = 'ALL';

    @wire(getQueueRequests)
    wiredRequests(result) {
        this.wiredResult = result;
        if (result.error) {
            this.errorMessage = result.error?.body?.message ?? 'Could not load requests.';
        } else if (result.data) {
            this.errorMessage = '';
        }
    }

    get selectedRecordUrl() {
        if (!this.selectedDescription) return null;
        const match = this.selectedDescription.match(/Record Link:\s*(https?:\/\/[^\s]+)/i);
        return match ? match[1] : null;
    }

    get cleanDescription() {
        if (!this.selectedDescription) return '';
        return this.selectedDescription.replace(/Record Link:\s*https?:\/\/[^\s]+\n?/i, '').trim();
    }

    // Full, un-sliced dataset mapped into view models
    get allRequestsList() {
        if (!this.wiredResult?.data) return [];
        return this.wiredResult.data.map((c) => {
            return {
                id: c.Id,
                subject: c.Subject || 'No Subject',
                status: c.Status,
                statusLabel: STATUS_LABEL[c.Status] || c.Status,
                description: c.Description || 'No description provided.',
                requesterName: c.Contact?.Name || 'Unknown Requester',
                rowClass: STATUS_ROW_CLASS[c.Status] || 'request-row',
                badgeClass: STATUS_BADGE_CLASS[c.Status] || 'badge badge_muted',
                date: c.CreatedDate
                    ? new Date(c.CreatedDate).toLocaleDateString([], {
                          day: '2-digit',
                          month: 'short',
                          year: 'numeric'
                      })
                    : 'No Date'
            };
        });
    }

    // Filtered list displayed on the screen
    get displayRequests() {
        if (this.selectedFilter === 'ALL') {
            return this.allRequestsList;
        }
        return this.allRequestsList.filter((r) => r.status === this.selectedFilter);
    }

    get totalCount() {
        return this.allRequestsList.length;
    }

    get openCount() {
        return this.allRequestsList.filter((r) => r.status === 'New').length;
    }

    get progressCount() {
        return this.allRequestsList.filter((r) => r.status === 'Working').length;
    }

    get completedCount() {
        return this.allRequestsList.filter((r) => r.status === 'Closed').length;
    }

    // Active button styling getters
    get allFilterClass() {
        return `filter-btn ${this.selectedFilter === 'ALL' ? 'filter-btn_active' : ''}`;
    }

    get openFilterClass() {
        return `filter-btn stat-open ${this.selectedFilter === 'New' ? 'filter-btn_active stat-open_active' : ''}`;
    }

    get progressFilterClass() {
        return `filter-btn stat-progress ${this.selectedFilter === 'Working' ? 'filter-btn_active stat-progress_active' : ''}`;
    }

    get completedFilterClass() {
        return `filter-btn stat-completed ${this.selectedFilter === 'Closed' ? 'filter-btn_active stat-completed_active' : ''}`;
    }

    handleFilterChange(event) {
        this.selectedFilter = event.currentTarget.dataset.filter;
    }

    get hasRequests() {
        return this.displayRequests.length > 0;
    }

    get noRequests() {
        return !!this.wiredResult?.data && this.displayRequests.length === 0;
    }

    get hasError() {
        return !!this.errorMessage;
    }

    get isLoading() {
        return !this.wiredResult;
    }

    get hasFormError() {
        return !!this.formError;
    }

    get isSubmitDisabled() {
        return this.isSubmitting || !this.selectedStatus;
    }

    handleRowClick(event) {
        const id = event.currentTarget.dataset.id;
        const request = this.allRequestsList.find((r) => r.id === id);
        if (request) {
            this.selectedCaseId = id;
            this.selectedRequester = request.requesterName;
            this.selectedSubject = request.subject;
            this.selectedDescription = request.description;
            this.selectedStatus = request.status;
            this.originalStatus = request.status;
            this.formError = '';
            this.isModalOpen = true;

            // Bust cache and sync comments fresh from server
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                const thread = this.template.querySelector('c-case-comment-thread');
                if (thread) {
                    thread.refresh();
                }
            }, 0);
        }
    }

    handleCloseModal() {
        if (this.isSubmitting) return;
        this.resetModalState();
    }

    resetModalState() {
        this.isModalOpen = false;
        this.selectedCaseId = null;
        this.selectedRequester = '';
        this.selectedSubject = '';
        this.selectedDescription = '';
        this.selectedStatus = '';
        this.originalStatus = '';
        this.formError = '';
    }

    handleModalContentClick(event) {
        event.stopPropagation();
    }

    handleStatusChange(event) {
        this.selectedStatus = event.detail.value;
    }

    async handleRefresh() {
        this.isRefreshing = true;
        try {
            await refreshApex(this.wiredResult);
        } finally {
            this.isRefreshing = false;
        }
    }

    async handleSave() {
        this.formError = '';

        if (!this.selectedCaseId) {
            this.formError = 'No request selected.';
            return;
        }

        const threadCmp = this.template.querySelector('c-case-comment-thread');
        const draftComment = threadCmp ? threadCmp.draftComment : '';
        const isStatusChanged = this.selectedStatus && this.selectedStatus !== this.originalStatus;
        const isCommentAdded = Boolean(draftComment);

        if (!isStatusChanged && !isCommentAdded) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'No Changes',
                    message: 'No status updates or comments to save.',
                    variant: 'info'
                })
            );
            this.resetModalState();
            return;
        }

        this.isSubmitting = true;
        try {
            await saveRequestAndComment({
                caseId: this.selectedCaseId,
                newStatus: isStatusChanged ? this.selectedStatus : null,
                commentBody: isCommentAdded ? draftComment : null
            });

            if (threadCmp) {
                threadCmp.clearDraft();
            }

            await refreshApex(this.wiredResult);
            this.resetModalState();

            let successMessage = 'Request updated successfully.';
            if (isStatusChanged && isCommentAdded) {
                successMessage = 'Status updated and comment added.';
            } else if (isStatusChanged) {
                successMessage = `Status updated to ${STATUS_LABEL[this.selectedStatus] || this.selectedStatus}.`;
            } else if (isCommentAdded) {
                successMessage = 'Comment posted successfully.';
            }

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: successMessage,
                    variant: 'success'
                })
            );
        } catch (error) {
            this.formError = error?.body?.message || 'Unable to save changes. Please try again.';
        } finally {
            this.isSubmitting = false;
        }
    }
}