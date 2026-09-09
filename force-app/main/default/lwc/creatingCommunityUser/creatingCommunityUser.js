import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import createContactAndUser from '@salesforce/apex/CreateCommunityUserFromFlow.createContactAndUser';

export default class CreatingCommunityUser extends LightningElement {
    @track firstName         = '';
    @track lastName          = '';
    @track email             = '';
    @track phone             = '';
    @track selectedAccountId = '';
    @track userType          = '';
    @track message           = '';
    @track isLoading         = false;
    @track isSuccess         = false;

    // Only Mentor and Team Member — HR removed from UI
    userTypeOptions = [
        { label: 'Mentor',      value: 'Mentor'      },
        { label: 'Team Member', value: 'Team Member'  }
    ];

    handleChange(event) {
        const field = event.target.dataset.field;
        this[field] = event.target.value;
    }

    // Handles lightning-record-picker change
    handleAccountChange(event) {
        this.selectedAccountId = event.detail.recordId || null;
    }

    handleUserTypeChange(event) {
        this.userType = event.detail.value;
    }

    handleSubmit() {
        // Validate required fields
        if (!this.firstName || !this.lastName ||
            !this.email     || !this.selectedAccountId || !this.userType) {
            this.showToast('Validation Error', 'Please fill in all required fields.', 'error');
            return;
        }

        // Extra safety check for HR
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
            userType  : this.userType
        })
        .then(result => {
            if (result === 'Success') {
                // ✅ Show Toast Message on Successful Creation
                this.showToast(
                    'Success!',
                    `User ${this.firstName} ${this.lastName} was created successfully. Welcome email sent to ${this.email}.`,
                    'success'
                );
                
                this.isSuccess = true;
                this.resetForm();

                // ✅ Fire event to notify parent (adminAssessmentDashboard) to close the modal
                this.dispatchEvent(new CustomEvent('usercreated', {
                    detail: {
                        firstName: this.firstName,
                        lastName: this.lastName,
                        email: this.email
                    }
                }));
            } else {
                // Handle Apex custom error return strings
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

    // Helper Method to Dispatch Toast Events
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
    this.selectedAccountId = null; // ✅ Set track property to null/empty
    this.userType          = '';
    this.message           = '';

    // ✅ Target the record picker and clear its value attribute directly
    const recordPicker = this.template.querySelector('lightning-record-picker');
    if (recordPicker) {
        recordPicker.value = null; 
    }
}

    get messageClass() {
        return this.isSuccess
            ? 'slds-text-color_success slds-m-top_small'
            : 'slds-text-color_error slds-m-top_small';
    }
}