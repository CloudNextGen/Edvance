import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getExperienceUsers from '@salesforce/apex/AdminDashboardController.getExperienceUsers';
import getCategories from '@salesforce/apex/AdminDashboardController.getCategories';
import getAdminAssignmentsForCategory from '@salesforce/apex/AdminDashboardController.getAdminAssignmentsForCategory';
import getAdminSubmissionAttempts from '@salesforce/apex/AdminDashboardController.getAdminSubmissionAttempts';
import getAdminSubmissionDetail from '@salesforce/apex/AdminDashboardController.getAdminSubmissionDetail';
import getPendingAppealsForDashboard from '@salesforce/apex/AttendanceAdminController.getPendingAppealsForDashboard';
import reviewSelectedAppeals from '@salesforce/apex/AttendanceAdminController.reviewSelectedAppeals';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import canViewAssignments from '@salesforce/customPermission/View_Assignments';
import canAssignFiles from '@salesforce/customPermission/Assign_Files';
import canViewAttendance from '@salesforce/customPermission/View_Attendance';

export default class AdminAssessmentDashboard extends LightningElement {
    @track users = [];
    @track categories = [];
    @track assignments = [];
    @track attempts = [];
    @track attemptDetail = [];
    @track pendingAppeals = [];
    selectedAppealIds = [];

    searchTerm = '';

    // Screen Toggles
    showUserScreen = true;
    showCategoryScreen = false;
    showAssignmentScreen = false;
    showAttemptsScreen = false;
    showReviewScreen = false;
    showAppealsScreen = false;
    isLoading = false;
    isAppealsLoading = false;
    selectedAppeal;
    showAppealDetail = false;
    isReviewingAppeal = false;

    // Selections State
    selectedContactId;
    selectedUserName;
    selectedCategoryId;
    selectedCategoryName;
    selectedAssignmentId;
    selectedAssignmentTitle;
    selectedAttemptId;
    selectedAttemptNumber;
    showAssignModal = false;
    showAttendanceScreen = false;
    showAssignAssignmentsModal = false;

    // Edit User Modal
    showEditUserModal = false;

    showCreateUserModal = false;
    isRefreshingAppeals = false;
    appealsRefreshQueued = false;
    appealsRefreshRequestId = 0;
    wiredUsersResult;

    get showCreateUserLink() { return canViewAttendance; }
    get hasNoPendingAppeals() {
        return !this.isAppealsLoading && this.pendingAppeals.length === 0;
    }
    get hasSelectedAppeals() {
        return this.selectedAppealIds.length > 0;
    }
    get selectedAppealCount() {
        return this.selectedAppealIds.length;
    }
    get disableSelectedReviewActions() {
        return !this.hasSelectedAppeals || this.isReviewingAppeal;
    }

    // Unmounts search bar when modal is up to prevent quick-fill email injection into search
    get isModalOpen() {
        return this.showCreateUserModal || 
               this.showEditUserModal || 
               this.showAssignModal || 
               this.showAssignAssignmentsModal;
    }

    handleOpenAppeals() {
        this.showUserScreen = false;
        this.showAppealsScreen = true;
        this.loadPendingAppeals();
    }

    handleRefreshAppeals() {
        this.loadPendingAppeals();
    }

    handleBackFromAppeals() {
        this.showAppealsScreen = false;
        this.showUserScreen = true;
        this.showAppealDetail = false;
        this.selectedAppeal = undefined;
        this.selectedAppealIds = [];
    }

    async loadPendingAppeals({ force = false, showLoading = true } = {}) {
        const forceRefresh = force;
        if (this.isRefreshingAppeals && !forceRefresh) {
            this.appealsRefreshQueued = true;
            return;
        }
        if (forceRefresh) this.appealsRefreshQueued = false;
        const requestId = ++this.appealsRefreshRequestId;
        this.isRefreshingAppeals = true;
        if (showLoading) this.isAppealsLoading = true;
        const selectedIdsBeforeRefresh = new Set(this.selectedAppealIds);
        try {
            const appeals = await getPendingAppealsForDashboard();
            if (requestId !== this.appealsRefreshRequestId) return;
            this.pendingAppeals = appeals.map((appeal) => ({
                ...appeal,
                EmployeeName: appeal.Employee__r?.Name || 'Unknown user',
                AppealDate: appeal.Attendance_Summary__r?.Date__c || null,
                CurrentDeductionLabel: `₹${Number(appeal.Deduction_Amount__c || 0).toFixed(2)}`,
                AppealReason: appeal.Excusal_Reason__c || 'No reason provided',
                isSelected: selectedIdsBeforeRefresh.has(appeal.Id)
            }));
            this.selectedAppealIds = this.pendingAppeals
                .filter((appeal) => appeal.isSelected)
                .map((appeal) => appeal.Id);
            if (this.selectedAppeal) {
                this.selectedAppeal = this.pendingAppeals.find((appeal) => appeal.Id === this.selectedAppeal.Id);
                if (!this.selectedAppeal) this.showAppealDetail = false;
            }
        } catch (error) {
            if (requestId === this.appealsRefreshRequestId) {
                this.showToast('Error', error?.body?.message ?? error?.message ?? 'Could not load pending appeals.', 'error');
            }
        } finally {
            if (requestId === this.appealsRefreshRequestId) {
                if (showLoading) this.isAppealsLoading = false;
                this.isRefreshingAppeals = false;
            }
            if (requestId === this.appealsRefreshRequestId && this.appealsRefreshQueued && this.showAppealsScreen) {
                this.appealsRefreshQueued = false;
                this.loadPendingAppeals({ showLoading: false });
            }
        }
    }

    handleViewAppeal(event) {
        const appealId = event.currentTarget.dataset.id;
        this.selectedAppeal = this.pendingAppeals.find((appeal) => appeal.Id === appealId);
        this.showAppealDetail = true;
        this.selectedAppealIds = [];
        this.syncAppealSelection();
    }

    handleAppealSelection(event) {
        const appealId = event.currentTarget.dataset.id;
        if (event.target.checked) {
            this.selectedAppealIds = [...new Set([...this.selectedAppealIds, appealId])];
        } else {
            this.selectedAppealIds = this.selectedAppealIds.filter((id) => id !== appealId);
        }
        this.syncAppealSelection();
    }

    syncAppealSelection() {
        const selectedIds = new Set(this.selectedAppealIds);
        this.pendingAppeals = this.pendingAppeals.map((appeal) => ({
            ...appeal,
            isSelected: selectedIds.has(appeal.Id)
        }));
    }

    async reviewSelected(approve) {
        if (this.isReviewingAppeal || !this.hasSelectedAppeals) return;
        this.isReviewingAppeal = true;
        const selectedCount = this.selectedAppealIds.length;
        try {
            const reviewedCount = await reviewSelectedAppeals({
                logIds: this.selectedAppealIds,
                approve
            });
            this.showToast('Success', `${reviewedCount} of ${selectedCount} selected appeal(s) ${approve ? 'approved' : 'rejected'}.`, 'success');
            const reviewedIds = new Set(this.selectedAppealIds);
            this.pendingAppeals = this.pendingAppeals.filter((appeal) => !reviewedIds.has(appeal.Id));
            this.selectedAppealIds = [];
            await this.loadPendingAppeals({ showLoading: false, force: true });
        } catch (error) {
            this.showToast('Error', error?.body?.message ?? error?.message ?? 'Could not review selected appeals.', 'error');
        } finally {
            this.isReviewingAppeal = false;
        }
    }

    handleApproveSelected() {
        this.reviewSelected(true);
    }

    handleRejectSelected() {
        this.reviewSelected(false);
    }

    handleCloseAppealDetail() {
        this.showAppealDetail = false;
        this.selectedAppeal = undefined;
        this.selectedAppealIds = [];
        this.syncAppealSelection();
    }

    // ── Create User Handling ──
    handleOpenCreateUser() {
        this.searchTerm = '';
        this.showCreateUserModal = true;
    }

    handleCloseCreateUser() {
        this.showCreateUserModal = false;
        this.searchTerm = '';
    }

    async handleCreateUserSuccess(event) {
        if (event) {
            event.stopPropagation();
        }
        this.showCreateUserModal = false;
        this.searchTerm = '';
        this.showToast('Success', 'User created successfully.', 'success');

        if (this.wiredUsersResult) {
            try {
                await refreshApex(this.wiredUsersResult);
                setTimeout(async () => {
                    await refreshApex(this.wiredUsersResult);
                }, 1200);
            } catch (error) {
                this.showToast('Notice', 'User created, roster refresh pending.', 'info');
            }
        }
    }

    // ── Edit Contact Handlers ──
    handleOpenEditUser(event) {
        event.stopPropagation();
        this.selectedContactId = event.currentTarget.dataset.id;
        this.selectedUserName = event.currentTarget.dataset.name;
        this.showEditUserModal = true;
    }

    handleCloseEditUser() {
        this.showEditUserModal = false;
    }

    async handleEditSuccess() {
        this.showToast('Success', 'Contact updated successfully.', 'success');
        this.showEditUserModal = false;
        if (this.wiredUsersResult) {
            await refreshApex(this.wiredUsersResult);
        }
    }

    handleEditError(event) {
        this.showToast('Error', event.detail?.message || 'Could not update contact record.', 'error');
    }

    get showAssignmentsLink() { return canViewAssignments; }
    get showAssignFilesLink() { return canAssignFiles; }
    get showAttendanceLink() { return canViewAttendance; }

    @wire(getExperienceUsers)
    wiredUsers(result) {
        this.wiredUsersResult = result;
        const { error, data } = result;
        if (data) {
            this.users = data.map(u => ({
                ...u,
                hasEmail: Boolean(u.Email && u.Email.trim().length > 0),
                hasPhone: Boolean(u.Phone && u.Phone.trim().length > 0),
                PhoneDisplay: u.Phone ? u.Phone.trim() : '',
                EmailDisplay: u.Email ? u.Email.trim() : '',
                AccountName: u.Account?.Name || 'CloudNextGen IT Software Solutions LLP'
            }));
        } else if (error) {
            this.showToast('Error', 'Failed to retrieve active roster profiles.', 'error');
        }
    }

    @wire(getCategories)
    wiredCategories({ error, data }) {
        if (data) this.categories = data;
        else if (error) this.showToast('Error', 'Failed to retrieve categories.', 'error');
    }

    handleUserClick(event) {
        this.selectedContactId = event.currentTarget.dataset.id;
        this.selectedUserName = event.currentTarget.dataset.name;
        this.showUserScreen = false;
        this.showCategoryScreen = true;
    }

    handleCategoryClick(event) {
        this.selectedCategoryId = event.currentTarget.dataset.id;
        this.selectedCategoryName = event.currentTarget.dataset.name;
        this.fetchAssignments();
    }

    handleOpenAssign(event) {
        event.stopPropagation();
        this.selectedContactId = event.currentTarget.dataset.contactId;
        this.selectedUserName = event.currentTarget.dataset.name;
        this.showAssignModal = true;
    }

    handleCloseAssign() {
        this.showAssignModal = false;
        this.selectedContactId = undefined;
        this.selectedUserName = undefined;
    }

    handleOpenAttendance(event) {
        event.stopPropagation();
        this.selectedContactId = event.currentTarget.dataset.contactId;
        this.selectedUserName = event.currentTarget.dataset.name;
        this.showUserScreen = false;
        this.showAttendanceScreen = true;
    }

    handleBackFromAttendance() {
        this.showAttendanceScreen = false;
        this.showUserScreen = true;
        this.selectedContactId = undefined;
        this.selectedUserName = undefined;
    }

    handleOpenAssignAssignments(event) {
        event.stopPropagation();
        this.selectedContactId = event.currentTarget.dataset.contactId;
        this.selectedUserName = event.currentTarget.dataset.name;
        this.showAssignAssignmentsModal = true;
    }

    handleCloseAssignAssignments() {
        this.showAssignAssignmentsModal = false;
        this.selectedContactId = undefined;
        this.selectedUserName = undefined;
    }

    fetchAssignments() {
        this.isLoading = true;
        getAdminAssignmentsForCategory({ categoryId: this.selectedCategoryId, contactId: this.selectedContactId })
            .then(result => {
                this.assignments = result.map(asm => {
                    let rClass = 'assignment-row';
                    if (asm.isCompletedStatus) rClass += ' is-completed';
                    if (asm.isLockedStatus) rClass += ' is-locked';
                    return { ...asm, rowClass: rClass };
                });
                this.showCategoryScreen = false;
                this.showAssignmentScreen = true;
            })
            .catch(err => this.showToast('Error', err?.body?.message ?? err?.message ?? 'An unexpected error occurred.', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    handleViewAttempts(event) {
        this.selectedAssignmentId = event.currentTarget.dataset.id;
        this.selectedAssignmentTitle = event.currentTarget.dataset.title;
        this.isLoading = true;

        getAdminSubmissionAttempts({ assignmentId: this.selectedAssignmentId, contactId: this.selectedContactId })
            .then(result => {
                this.attempts = result;
                this.showAssignmentScreen = false;
                this.showAttemptsScreen = true;
            })
            .catch(err => this.showToast('Error', err?.body?.message ?? err?.message ?? 'An unexpected error occurred.', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    handleAttemptClick(event) {
        this.selectedAttemptId = event.currentTarget.dataset.id;
        this.selectedAttemptNumber = event.currentTarget.dataset.attempt;
        this.isLoading = true;

        getAdminSubmissionDetail({ submissionId: this.selectedAttemptId })
            .then(result => {
                this.attemptDetail = result.map((item, idx) => ({
                    ...item,
                    displayIndex: idx + 1
                }));
                this.showAttemptsScreen = false;
                this.showReviewScreen = true;
            })
            .catch(err => this.showToast('Error', err?.body?.message ?? err?.message ?? 'An unexpected error occurred.', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    navBackToUsers() {
        this.showCategoryScreen = false;
        this.showUserScreen = true;
    }
    navBackToCategories() {
        this.showAssignmentScreen = false;
        this.showCategoryScreen = true;
    }
    navBackToAssignments() {
        this.showAttemptsScreen = false;
        this.showAssignmentScreen = true;
    }
    navBackToAttempts() {
        this.showReviewScreen = false;
        this.showAttemptsScreen = true;
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    get filteredUsers() {
        if (!this.searchTerm) {
            return this.users;
        }
        const term = this.searchTerm.toLowerCase();
        return this.users.filter(u => {
            const name = (u.Name || '').toLowerCase();
            const email = (u.Email || '').toLowerCase();
            return name.includes(term) || email.includes(term);
        });
    }

    get hasNoSearchResults() {
        return this.searchTerm && this.filteredUsers.length === 0;
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
    }

    handleClearSearch() {
        this.searchTerm = '';
    }
}