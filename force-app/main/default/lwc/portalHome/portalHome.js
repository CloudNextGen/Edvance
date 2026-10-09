import { LightningElement, wire, api } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import Id from '@salesforce/user/Id';
import FIRST_NAME_FIELD from '@salesforce/schema/User.FirstName';
import getRecentFiles from '@salesforce/apex/LearningContentController.getRecentFiles';
import recordFileOpened from '@salesforce/apex/LearningContentController.recordFileOpened';
import getProfileDetails from '@salesforce/apex/PortalHomeController.getProfileDetails';
import getIsCommunityUser from '@salesforce/apex/PortalHomeController.isCommunityUser';
import raiseRequest from '@salesforce/apex/PortalRequestService.raiseRequest';

const REQUEST_TYPES = ['HR Related Query', 'Manager Related Query'];
const DEFAULT_HERO_SUBTITLE =
    'Everything you need to check in, learn, complete assignments, and track your onboarding — all in one place.';

export default class PortalHome extends LightningElement {
    // Configurable from Experience Builder (property panel)
    @api heroSubtitle = DEFAULT_HERO_SUBTITLE;

    userId = Id;
    recentFiles = [];
    isLoadingRecent = true;
    profileDetails = {};
    isLoadingProfiles = true;

    isCommunityUser = false;
    isCheckingUserType = true;

    showRequestModal = false;
    requestType = REQUEST_TYPES[0];
    requestDescription = '';
    requestError;
    isSubmittingRequest = false;

    requestTypeOptions = REQUEST_TYPES;

    @wire(getRecord, { recordId: '$userId', fields: [FIRST_NAME_FIELD] })
    userRecord;

    get userFirstName() {
        return this.userRecord?.data
            ? getUserFieldValue(this.userRecord.data, FIRST_NAME_FIELD)
            : '';
    }

    get welcomeMessage() {
        return this.userFirstName ? `Welcome back, ${this.userFirstName}` : 'Welcome back';
    }

    connectedCallback() {
        this.loadRecentFiles();
        getIsCommunityUser()
            .then((result) => {
                this.isCommunityUser = result;
                if (this.isCommunityUser) {
                    this.loadRecentFiles();
                    this.loadProfileDetails();
                }
            })
            .catch(() => {
                // fail closed: an internal/admin user should never fall
                // through to portal content if this check errors
                this.isCommunityUser = false;
            })
            .finally(() => {
                this.isCheckingUserType = false;
            });
    }

    loadProfileDetails() {
        this.isLoadingProfiles = true;
        getProfileDetails()
            .then((data) => {
                this.profileDetails = data || {};
            })
            .catch(() => {
                this.profileDetails = {};
            })
            .finally(() => {
                this.isLoadingProfiles = false;
            });
    }

    loadRecentFiles() {
        this.isLoadingRecent = true;
        getRecentFiles({ limitCount: 5 })
            .then((data) => {
                this.recentFiles = (data || []).map((recentFile) => ({
                    ...recentFile,
                    relativeTime: formatAccessTimeAgo(recentFile.lastAccessed),
                    iconLetter: (recentFile.name || '?').charAt(0).toUpperCase()
                }));
            })
            .catch(() => {
                this.recentFiles = [];
            })
            .finally(() => {
                this.isLoadingRecent = false;
            });
    }

    get hasRecentFiles() {
        return this.recentFiles.length > 0;
    }

    get showRecentSection() {
        return !this.isLoadingRecent && this.hasRecentFiles;
    }

    get profileCards() {
        const cards = [];

        if (this.profileDetails?.hr) {
            cards.push({
                key: 'hr',
                label: 'HR',
                profile: this.profileDetails.hr
            });
        }

        if (this.profileDetails?.manager) {
            cards.push({
                key: 'manager',
                label: 'Manager',
                profile: this.profileDetails.manager
            });
        }

        if (this.profileDetails?.mentor) {
            cards.push({
                key: 'mentor',
                label: 'Mentor',
                profile: this.profileDetails.mentor
            });
        }

        return cards;
    }

    get hasProfileCards() {
        return this.profileCards.length > 0;
    }

    get showProfileSection() {
        return this.isCommunityUser && !this.isLoadingProfiles && this.hasProfileCards;
    }

    handleRecentFileClick(event) {
        const fileId = event.currentTarget.dataset.id;
        const url = event.currentTarget.dataset.url;

        recordFileOpened({ fileId }).catch(() => {
            /* swallow - non-critical for navigation */
        });

        if (url) {
            window.open(url, '_blank', 'noopener,noreferrer');
        } else {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Link unavailable',
                    message: "This file doesn't have a link configured yet.",
                    variant: 'warning'
                })
            );
        }
    }

    handleOpenRequestModal() {
        this.requestType = REQUEST_TYPES[0];
        this.requestDescription = '';
        this.requestError = undefined;
        this.showRequestModal = true;
    }

    handleCloseRequestModal() {
        this.showRequestModal = false;
    }

    stopPropagation(event) {
        event.stopPropagation();
    }

    handleRequestTypeChange(event) {
        this.requestType = event.target.value;
    }

    handleRequestDescriptionChange(event) {
        this.requestDescription = event.target.value;
    }

    handleSubmitRequest() {
        if (!this.requestDescription || !this.requestDescription.trim()) {
            this.requestError = 'Please describe your request.';
            return;
        }

        this.isSubmittingRequest = true;
        this.requestError = undefined;

        raiseRequest({
            requestType: this.requestType,
            subject: null,
            description: this.requestDescription,
            relatedRecordId: null
        })
            .then(() => {
                this.showRequestModal = false;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Request submitted',
                        message: 'Our team will get back to you shortly.',
                        variant: 'success'
                    })
                );
            })
            .catch((error) => {
                this.requestError = error?.body?.message || error?.message || 'Something went wrong.';
            })
            .finally(() => {
                this.isSubmittingRequest = false;
            });
    }
}

function getUserFieldValue(userRecord, fieldReference) {
    const fieldName = fieldReference.fieldApiName;
    return userRecord?.fields?.[fieldName]?.value || '';
}

function formatAccessTimeAgo(dateTimeValue) {
    if (!dateTimeValue) return '';
    const accessTimestamp = new Date(dateTimeValue).getTime();
    const currentTimestamp = Date.now();
    const minutesSinceAccess = Math.floor((currentTimestamp - accessTimestamp) / 60000);
    if (minutesSinceAccess < 1) return 'Just now';
    if (minutesSinceAccess < 60) return `${minutesSinceAccess} min ago`;
    const hoursSinceAccess = Math.floor(minutesSinceAccess / 60);
    if (hoursSinceAccess < 24) return `${hoursSinceAccess} hr ago`;
    const daysSinceAccess = Math.floor(hoursSinceAccess / 24);
    return `${daysSinceAccess} day${daysSinceAccess === 1 ? '' : 's'} ago`;
}