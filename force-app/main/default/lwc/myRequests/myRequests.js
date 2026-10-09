import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getMyRequests from '@salesforce/apex/PortalRequestService.getMyRequests';
import raiseRequest from '@salesforce/apex/PortalRequestService.raiseRequest';

const STATUS_LABEL = {
    New: 'Not Started',
    Working: 'In Progress',
    Closed: 'Completed'
};

const STATUS_ROW_CLASS = {
    New: 'request-row request-row_open',
    Working: 'request-row request-row_progress',
    Closed: 'request-row request-row_completed'
};

const STATUS_BADGE_CLASS = {
    New: 'badge badge_info',
    Working: 'badge badge_warning',
    Closed: 'badge badge_success'
};

const REQUEST_TYPE_OPTIONS = [
    { label: 'HR Related Query', value: 'HR Related Query' },
    { label: 'Manager Related Query', value: 'Manager Related Query' }
];

export default class MyRequests extends LightningElement {
    wiredResult;
    errorMessage = '';
    isRefreshing = false;

    // Row expand/collapse state
    expandedIds = new Set();

    // New Request modal state
    isModalOpen = false;
    isSubmitting = false;
    formError = '';
    requestTypeOptions = REQUEST_TYPE_OPTIONS;
    formRequestType = '';
    formSubject = '';
    formDescription = '';

    @wire(getMyRequests)
    wiredRequests(result) {
        this.wiredResult = result;
        if (result.error) {
            this.errorMessage = result.error?.body?.message ?? 'Could not load your requests.';
        } else if (result.data) {
            this.errorMessage = '';
        }
    }

    get displayRequests() {
        if (!this.wiredResult?.data) return [];
        return this.wiredResult.data.map((c) => {
            const isExpanded = this.expandedIds.has(c.Id);
            return {
                id: c.Id,
                subject: c.Subject,
                status: c.Status,
                statusLabel: STATUS_LABEL[c.Status] || c.Status,
                description: c.Description,
                rowClass: (STATUS_ROW_CLASS[c.Status] || 'request-row') + (isExpanded ? ' request-row_expanded' : ''),
                badgeClass: STATUS_BADGE_CLASS[c.Status] || 'badge badge_muted',
                chevronClass: 'chevron-icon' + (isExpanded ? ' chevron-icon_open' : ''),
                isExpanded,
                date: new Date(c.CreatedDate).toLocaleDateString([], { day: '2-digit', month: 'short', year: 'numeric' })
            };
        });
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
        return (
            this.isSubmitting ||
            !this.formRequestType?.trim() ||
            !this.formSubject?.trim() ||
            !this.formDescription?.trim()
        );
    }

    handleRowToggle(event) {
        const id = event.currentTarget.dataset.id;
        if (this.expandedIds.has(id)) {
            this.expandedIds.delete(id);
        } else {
            this.expandedIds.add(id);
        }
        this.expandedIds = new Set(this.expandedIds);
    }

    handleOpenModal() {
        this.formRequestType = '';
        this.formSubject = '';
        this.formDescription = '';
        this.formError = '';
        this.isModalOpen = true;
    }

    handleCloseModal() {
        if (this.isSubmitting) return;
        this.isModalOpen = false;
    }

    handleModalContentClick(event) {
        event.stopPropagation();
    }

    handleTypeChange(event) {
        this.formRequestType = event.detail.value;
    }

    handleSubjectChange(event) {
        this.formSubject = event.target.value;
    }

    handleDescriptionChange(event) {
        this.formDescription = event.target.value;
    }

    validateInputs() {
        const inputFields = [
            ...this.template.querySelectorAll('lightning-combobox'),
            ...this.template.querySelectorAll('lightning-input'),
            ...this.template.querySelectorAll('lightning-textarea')
        ];

        return inputFields.reduce((validSoFar, inputCmp) => {
            inputCmp.reportValidity();
            return validSoFar && inputCmp.checkValidity();
        }, true);
    }

    async handleRefresh() {
        this.isRefreshing = true;
        try {
            await refreshApex(this.wiredResult);

            const threads = this.template.querySelectorAll('c-case-comment-thread');
            await Promise.all(Array.from(threads).map((t) => t.refresh()));
        } finally {
            this.isRefreshing = false;
        }
    }

    async handleSubmit() {
        this.formError = '';

        if (!this.validateInputs()) {
            this.formError = 'Please fill in all required fields.';
            return;
        }

        this.isSubmitting = true;
        try {
            const result = await raiseRequest({
                requestType: this.formRequestType.trim(),
                subject: this.formSubject.trim(),
                description: this.formDescription.trim()
            });

            this.isModalOpen = false;
            await refreshApex(this.wiredResult);

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Request Submitted',
                    message: result?.message || 'Your request has been submitted.',
                    variant: 'success'
                })
            );
        } catch (error) {
            this.formError = error?.body?.message || 'Unable to submit request. Please try again.';
        } finally {
            this.isSubmitting = false;
        }
    }
}