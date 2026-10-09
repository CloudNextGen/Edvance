import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import createContactAndUser from '@salesforce/apex/CreateCommunityUserFromFlow.createContactAndUser';

export default class CreatingCommunityUser extends LightningElement {
    @track firstName         = '';
    @track lastName          = '';
    @track email             = '';
    @track phone             = '';
    @track selectedAccountId = '';
    @track selectedHrId      = null;
    @track selectedManagerId = null;
    @track selectedMentorId  = null;
    @track userType          = '';
    @track message           = '';
    @track isLoading         = false;
    @track isSuccess         = false;

    userTypeOptions = [
        { label: 'Mentor',      value: 'Mentor'      },
        { label: 'Team Member', value: 'Team Member'  }
    ];

    handleChange(event) {
        const field = event.target.dataset.field;
        this[field] = event.target.value;
    }

    handleAccountChange(event) {
        this.selectedAccountId = event.detail.recordId || null;
    }

    handleHrChange(event) {
        this.selectedHrId = event.detail.recordId || null;
    }

    handleManagerChange(event) {
        this.selectedManagerId = event.detail.recordId || null;
    }

    handleMentorChange(event) {
        this.selectedMentorId = event.detail.recordId || null;
    }

    handleUserTypeChange(event) {
        this.userType = event.detail.value;
    }

    handleSubmit() {
        if (!this.firstName || !this.lastName ||
            !this.email     || !this.selectedAccountId || !this.userType) {
            this.showToast('Validation Error', 'Please fill in all required fields.', 'error');
            return;
        }

        if (this.userType === 'HR') {
            this.showToast('Validation Error', 'HR User Type cannot be created from this form.', 'error');
            return;
        }

        this.isLoading = true;
        this.message   = '';

        createContactAndUser({
            firstName : this.firstName,
            lastName  : this.lastName,
            email     : this.email,
            phone     : this.phone,
            accountId : this.selectedAccountId,
            userType  : this.userType,
            hrId      : this.selectedHrId,
            managerId : this.selectedManagerId,
            mentorId  : this.selectedMentorId
        })
        .then(result => {
            if (result === 'Success') {
                this.showToast(
                    'Success!',
                    `User ${this.firstName} ${this.lastName} was created successfully. Welcome email sent to ${this.email}.`,
                    'success'
                );
                
                this.isSuccess = true;
                this.resetForm();

                this.dispatchEvent(new CustomEvent('usercreated', {
                    detail: {
                        firstName: this.firstName,
                        lastName: this.lastName,
                        email: this.email
                    }
                }));
            } else {
                this.showToast('Creation Failed', result, 'error');
                this.message   = result;
                this.isSuccess = false;
            }
        })
        .catch(error => {
            const errorMsg = error.body ? error.body.message : error.message;
            this.showToast('Error', 'Error creating record: ' + errorMsg, 'error');
            this.message   = 'Error: ' + errorMsg;
            this.isSuccess = false;
        })
        .finally(() => {
            this.isLoading = false;
        });
    }

    showToast(title, message, variant) {
        const event = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant,
            mode: variant === 'success' ? 'dismissible' : 'sticky'
        });
        this.dispatchEvent(event);
    }

    resetForm() {
        this.firstName         = '';
        this.lastName          = '';
        this.email             = '';
        this.phone             = '';
        this.selectedAccountId = null;
        this.selectedHrId      = null;
        this.selectedManagerId = null;
        this.selectedMentorId  = null;
        this.userType          = '';
        this.message           = '';

        const pickers = this.template.querySelectorAll('lightning-record-picker');
        pickers.forEach(picker => {
            picker.value = null;
        });
    }

    get messageClass() {
        return this.isSuccess
            ? 'slds-text-color_success slds-m-top_small'
            : 'slds-text-color_error slds-m-top_small';
    }
}