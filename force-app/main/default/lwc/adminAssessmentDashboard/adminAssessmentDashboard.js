import { LightningElement, api, track, wire } from 'lwc';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import LightningConfirm from 'lightning/confirm';
import getExperienceUsers from '@salesforce/apex/AdminDashboardController.getExperienceUsers';
import getPortalUsersByStatus from '@salesforce/apex/AdminDashboardController.getPortalUsersByStatus';
import setPortalUserActive from '@salesforce/apex/AdminDashboardController.setPortalUserActive';
import getCategories from '@salesforce/apex/AdminDashboardController.getCategories';
import getAdminAssignmentsForCategory from '@salesforce/apex/AdminDashboardController.getAdminAssignmentsForCategory';
import getAdminSubmissionAttempts from '@salesforce/apex/AdminDashboardController.getAdminSubmissionAttempts';
import getAdminSubmissionDetail from '@salesforce/apex/AdminDashboardController.getAdminSubmissionDetail';
import getPendingAppealsForDashboard from '@salesforce/apex/AttendanceAdminController.getPendingAppealsForDashboard';
import reviewSelectedAppeals from '@salesforce/apex/AttendanceAdminController.reviewSelectedAppeals';
import isCurrentUserSystemAdministrator from '@salesforce/apex/LearningAccessAdminController.isCurrentUserSystemAdministrator';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { publish, MessageContext } from 'lightning/messageService';
import ATTENDANCE_DEDUCTION_REFRESH from '@salesforce/messageChannel/Attendance_Deduction_Refresh__c';
import canViewAssignments from '@salesforce/customPermission/View_Assignments';
import canAssignFiles from '@salesforce/customPermission/Assign_Files';
import canViewAttendance from '@salesforce/customPermission/View_Attendance';
import canManagePortalUsers from '@salesforce/customPermission/Portal_HR_Access';

const DASHBOARD_STATE_KEYS = [
    'c__screen',
    'c__contactId',
    'c__contactName',
    'c__categoryId',
    'c__categoryName',
    'c__assignmentId',
    'c__assignmentTitle',
    'c__attemptId',
    'c__attemptNumber',
    'c__appealId',
    'c__dashboardView',
    'c__attendanceContactId',
    'c__attendanceEmployeeName'
];

export default class AdminAssessmentDashboard extends NavigationMixin(LightningElement) {
    @api dashboardSubtitle = 'Select an external student or contact to view assignments and results.';

    @track users = [];
    @track categories = [];
    @track assignments = [];
    @track attempts = [];
    @track attemptDetail = [];
    @track pendingAppeals = [];
    selectedAppealIds = [];
    isSystemAdministrator = false;

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
    showUserStatusModal = false;
    userStatusMode;
    userStatusRows = [];
    userStatusSearch = '';
    userStatusHasMore = false;
    isLoadingUserStatus = false;
    userStatusError = '';
    isConfirmingUserStatus = false;
    isChangingUserStatus = false;
    selectedStatusUserId;
    selectedStatusUserName = '';
    userStatusRequestId = 0;
    userStatusSearchTimer;
    isRefreshingAppeals = false;
    appealsRefreshQueued = false;
    appealsRefreshRequestId = 0;
    pendingAppealIdToRestore = null;
    dashboardLoadRequestId = 0;
    wiredUsersResult;
    @wire(MessageContext) messageContext;
    currentPageReference;

    disconnectedCallback() {
        this.clearUserStatusSearchTimer();
    }

    @wire(CurrentPageReference)
    setCurrentPageReference(pageReference) {
        if (!pageReference) {
            return;
        }

        this.currentPageReference = pageReference;
        this.restoreDashboardView(pageReference.state || {});
    }

    restoreDashboardView(state) {
        const loadRequestId = ++this.dashboardLoadRequestId;
        const requestedScreen = state.c__screen || (state.c__attendanceContactId ? 'attendance' : 'users');
        const validScreens = ['users', 'categories', 'assignments', 'attempts', 'review', 'appeals', 'attendance'];
        const screen = validScreens.includes(requestedScreen) ? requestedScreen : 'users';
        this.isLoading = false;
        this.showUserScreen = screen === 'users';
        this.showCategoryScreen = screen === 'categories';
        this.showAssignmentScreen = screen === 'assignments';
        this.showAttemptsScreen = screen === 'attempts';
        this.showReviewScreen = screen === 'review';
        this.showAppealsScreen = screen === 'appeals';
        this.showAttendanceScreen = screen === 'attendance';

        this.selectedContactId = state.c__contactId || state.c__attendanceContactId || undefined;
        this.selectedUserName = state.c__contactName || state.c__attendanceEmployeeName || undefined;
        this.selectedCategoryId = state.c__categoryId || undefined;
        this.selectedCategoryName = state.c__categoryName || undefined;
        this.selectedAssignmentId = state.c__assignmentId || undefined;
        this.selectedAssignmentTitle = state.c__assignmentTitle || undefined;
        this.selectedAttemptId = state.c__attemptId || undefined;
        this.selectedAttemptNumber = state.c__attemptNumber || undefined;
        this.showAppealDetail = false;
        this.selectedAppeal = undefined;
        this.pendingAppealIdToRestore = null;

        if (screen === 'appeals') {
            this.pendingAppealIdToRestore = state.c__appealId || null;
            this.loadPendingAppeals();
        } else if (screen === 'assignments' && this.selectedContactId && this.selectedCategoryId) {
            this.fetchAssignments(loadRequestId);
        } else if (screen === 'attempts' && this.selectedContactId && this.selectedAssignmentId) {
            this.loadAttempts(loadRequestId);
        } else if (screen === 'review' && this.selectedAttemptId) {
            this.loadAttemptDetail(loadRequestId);
        }
    }

    navigateDashboardView(screen, values = {}, replace = false) {
        if (!this.currentPageReference) {
            this.showToast('Notice', 'The dashboard page state could not be updated.', 'warning');
            return;
        }

        const state = { ...this.currentPageReference.state };
        DASHBOARD_STATE_KEYS.forEach((key) => delete state[key]);
        if (screen !== 'users') {
            state.c__screen = screen;
        }
        Object.entries(values).forEach(([key, value]) => {
            if (value !== undefined && value !== null && value !== '') {
                state[`c__${key}`] = String(value);
            }
        });

        this[NavigationMixin.Navigate]({
            ...this.currentPageReference,
            state
        }, replace);
    }

    get showCreateUserLink() { return canViewAttendance; }
    get showManagePortalUsersButton() {
        return this.isSystemAdministrator || canManagePortalUsers;
    }
    get isActivateUserMode() {
        return this.userStatusMode === 'activate';
    }
    get isDeactivateUserMode() {
        return this.userStatusMode === 'deactivate';
    }
    get userStatusTitle() {
        return this.isActivateUserMode ? 'Activate a Deactivated User' : 'Deactivate an Active User';
    }
    get userStatusSearchPlaceholder() {
        return this.isActivateUserMode
            ? 'Search deactivated users by name or email'
            : 'Search active users by name or email';
    }
    get userStatusActionLabel() {
        return this.isActivateUserMode ? 'Activate' : 'Deactivate';
    }
    get hasUserStatusRows() {
        return this.userStatusRows.length > 0;
    }
    get userStatusCountLabel() {
        const count = this.userStatusRows.length;
        const userLabel = count === 1 ? 'user' : 'users';
        if (this.userStatusHasMore) {
            return `${count} ${userLabel} loaded. Scroll down to load more.`;
        }
        return `${count} ${userLabel} loaded. All matching users are shown.`;
    }
    get showUserStatusEmpty() {
        return !this.isLoadingUserStatus && !this.userStatusError && this.userStatusRows.length === 0;
    }
    get hasUserStatusError() {
        return Boolean(this.userStatusError);
    }
    get showUserStatusSpinner() {
        return this.isLoadingUserStatus || this.isChangingUserStatus;
    }
    get isUserStatusActionPending() {
        return this.isConfirmingUserStatus || this.isChangingUserStatus;
    }
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
    get disableAppealDetailReviewActions() {
        return !this.selectedAppeal || this.isReviewingAppeal;
    }

    // Unmounts search bar when modal is up to prevent quick-fill email injection into search
    get isModalOpen() {
        return this.showCreateUserModal || 
               this.showEditUserModal || 
               this.showAssignModal || 
               this.showAssignAssignmentsModal ||
               this.showUserStatusModal;
    }

    handleOpenAppeals() {
        this.navigateDashboardView('appeals');
    }

    handleRefreshAppeals() {
        this.loadPendingAppeals();
    }

    handleBackFromAppeals() {
        this.navigateDashboardView('users', {}, true);
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
            if (this.pendingAppealIdToRestore) {
                this.selectedAppeal = this.pendingAppeals.find(
                    (appeal) => appeal.Id === this.pendingAppealIdToRestore
                );
                this.showAppealDetail = !!this.selectedAppeal;
                this.pendingAppealIdToRestore = null;
                if (!this.selectedAppeal) {
                    this.navigateDashboardView('appeals', {}, true);
                }
            }
            this.selectedAppealIds = this.pendingAppeals
                .filter((appeal) => appeal.isSelected)
                .map((appeal) => appeal.Id);
            if (this.selectedAppeal) {
                this.selectedAppeal = this.pendingAppeals.find((appeal) => appeal.Id === this.selectedAppeal.Id);
                if (!this.selectedAppeal) {
                    this.showAppealDetail = false;
                    this.navigateDashboardView('appeals', {}, true);
                }
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
        this.navigateDashboardView('appeals', { appealId });
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
        const isDetailReview = this.showAppealDetail && !!this.selectedAppeal;
        const appealIds = isDetailReview ? [this.selectedAppeal.Id] : this.selectedAppealIds;
        if (this.isReviewingAppeal || appealIds.length === 0) return;
        this.isReviewingAppeal = true;
        const selectedCount = appealIds.length;
        try {
            const reviewedCount = await reviewSelectedAppeals({
                logIds: appealIds,
                approve
            });
            publish(this.messageContext, ATTENDANCE_DEDUCTION_REFRESH, {
                action: 'appealReviewed'
            });
            this.showToast('Success', `${reviewedCount} of ${selectedCount} selected appeal(s) ${approve ? 'approved' : 'rejected'}.`, 'success');
            const reviewedIds = new Set(appealIds);
            this.pendingAppeals = this.pendingAppeals.filter((appeal) => !reviewedIds.has(appeal.Id));
            this.selectedAppealIds = [];
            if (isDetailReview) {
                this.showAppealDetail = false;
                this.selectedAppeal = undefined;
                this.navigateDashboardView('appeals', {}, true);
            }
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
        this.navigateDashboardView('appeals', {}, true);
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

    handleOpenUserStatusModal() {
        this.clearUserStatusSearchTimer();
        this.showUserStatusModal = true;
        this.userStatusMode = undefined;
        this.userStatusSearch = '';
        this.userStatusRows = [];
        this.userStatusError = '';
        this.clearSelectedStatusUser();
    }

    handleCloseUserStatusModal() {
        this.showUserStatusModal = false;
        this.userStatusMode = undefined;
        this.clearSelectedStatusUser();
        this.userStatusRequestId += 1;
        this.isLoadingUserStatus = false;
        this.clearUserStatusSearchTimer();
    }

    handleSelectActivateMode() {
        this.clearUserStatusSearchTimer();
        this.userStatusMode = 'activate';
        this.userStatusSearch = '';
        this.clearSelectedStatusUser();
        this.loadUserStatusRows();
    }

    handleSelectDeactivateMode() {
        this.clearUserStatusSearchTimer();
        this.userStatusMode = 'deactivate';
        this.userStatusSearch = '';
        this.clearSelectedStatusUser();
        this.loadUserStatusRows();
    }

    clearUserStatusSearchTimer() {
        if (this.userStatusSearchTimer) {
            clearTimeout(this.userStatusSearchTimer);
            this.userStatusSearchTimer = undefined;
        }
    }

    handleBackToUserStatusActions() {
        this.clearUserStatusSearchTimer();
        this.userStatusRequestId += 1;
        this.isLoadingUserStatus = false;
        this.userStatusMode = undefined;
        this.userStatusRows = [];
        this.userStatusSearch = '';
        this.userStatusError = '';
        this.clearSelectedStatusUser();
    }

    handleUserStatusSearch(event) {
        this.userStatusSearch = event.target.value;
        this.userStatusRequestId += 1;
        this.userStatusRows = [];
        this.userStatusHasMore = false;
        this.userStatusError = '';
        this.isLoadingUserStatus = true;
        this.clearUserStatusSearchTimer();
        this.userStatusSearchTimer = setTimeout(() => {
            this.userStatusSearchTimer = undefined;
            this.loadUserStatusRows();
        }, 300);
    }

    async loadUserStatusRows({ append = false } = {}) {
        if (!this.userStatusMode || (append && this.isLoadingUserStatus)) {
            return;
        }
        const requestId = ++this.userStatusRequestId;
        const offsetSize = append ? this.userStatusRows.length : 0;
        this.isLoadingUserStatus = true;
        if (!append) {
            this.userStatusRows = [];
            this.userStatusHasMore = false;
            this.userStatusError = '';
        }
        try {
            const page = await getPortalUsersByStatus({
                active: this.isDeactivateUserMode,
                searchTerm: this.userStatusSearch,
                offsetSize
            });
            if (requestId !== this.userStatusRequestId) {
                return;
            }
            const rows = page.users.map((user) => ({
                ...user,
                actionClass: this.isActivateUserMode
                    ? 'user-status-action activate'
                    : 'user-status-action deactivate'
            }));
            this.userStatusRows = append ? [...this.userStatusRows, ...rows] : rows;
            this.userStatusHasMore = page.hasMore;
        } catch (error) {
            if (requestId === this.userStatusRequestId) {
                this.userStatusError = error?.body?.message || error?.message || 'Refresh and try again.';
                this.showToast(
                    'Could not load users',
                    this.userStatusError,
                    'error'
                );
            }
        } finally {
            if (requestId === this.userStatusRequestId) {
                this.isLoadingUserStatus = false;
            }
        }
    }

    handleUserStatusListScroll(event) {
        const list = event.currentTarget;
        if (
            this.userStatusHasMore &&
            !this.isLoadingUserStatus &&
            list.scrollTop + list.clientHeight >= list.scrollHeight - 40
        ) {
            this.loadUserStatusRows({ append: true });
        }
    }

    async handleChooseUserStatusChange(event) {
        if (this.isUserStatusActionPending) {
            return;
        }
        const button = event.currentTarget;
        const userId = button.dataset.userId;
        const userName = button.dataset.userName || 'the selected user';
        const activate = this.isActivateUserMode;
        this.isConfirmingUserStatus = true;
        try {
            const confirmed = await LightningConfirm.open({
                label: `${activate ? 'Activate' : 'Deactivate'} user`,
                message: `Are you sure you want to ${activate ? 'activate' : 'deactivate'} ${userName}?`,
                theme: activate ? 'default' : 'warning'
            });
            if (!confirmed || !this.showUserStatusModal) {
                return;
            }

            this.selectedStatusUserId = userId;
            this.selectedStatusUserName = userName;
        } finally {
            this.isConfirmingUserStatus = false;
        }
        if (this.selectedStatusUserId) {
            await this.handleConfirmUserStatusChange();
        }
    }

    clearSelectedStatusUser() {
        this.selectedStatusUserId = undefined;
        this.selectedStatusUserName = '';
    }

    async handleConfirmUserStatusChange() {
        if (!this.selectedStatusUserId || this.isChangingUserStatus) {
            return;
        }
        const userToUpdate = {
            id: this.selectedStatusUserId,
            name: this.selectedStatusUserName
        };
        this.isChangingUserStatus = true;
        try {
            await setPortalUserActive({
                userId: userToUpdate.id,
                active: this.isActivateUserMode
            });
            this.showToast(
                'Success',
                `${userToUpdate.name} was ${this.isActivateUserMode ? 'activated' : 'deactivated'}.`,
                'success'
            );
            this.clearSelectedStatusUser();
            this.userStatusRequestId += 1;
            this.isLoadingUserStatus = false;
            await this.loadUserStatusRows();
            if (this.wiredUsersResult) {
                await refreshApex(this.wiredUsersResult);
            }
        } catch (error) {
            this.showToast(
                'Could not update user',
                error?.body?.message || error?.message || 'Refresh and try again.',
                'error'
            );
        } finally {
            this.isChangingUserStatus = false;
            this.clearSelectedStatusUser();
        }
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

    get showAssignmentsLink() { return this.isSystemAdministrator || canViewAssignments; }
    get showAssignFilesLink() { return this.isSystemAdministrator || canAssignFiles; }
    get showAttendanceLink() { return canViewAttendance; }

    @wire(isCurrentUserSystemAdministrator)
    wiredSystemAdministrator({ data, error }) {
        if (data !== undefined) {
            this.isSystemAdministrator = data;
        } else if (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Unable to verify administrator access',
                message: error.body?.message || 'Refresh the page and try again.',
                variant: 'error'
            }));
        }
    }

    @wire(getExperienceUsers)
    wiredUsers(result) {
        this.wiredUsersResult = result;
        const { error, data } = result;
        if (data) {
            this.users = data.map(user => ({
                ...user,
                hasEmail: Boolean(user.Email && user.Email.trim().length > 0),
                hasPhone: Boolean(user.Phone && user.Phone.trim().length > 0),
                PhoneDisplay: user.Phone ? user.Phone.trim() : '',
                EmailDisplay: user.Email ? user.Email.trim() : '',
                AccountName: user.Account?.Name || 'CloudNextGen IT Software Solutions LLP'
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
        this.navigateDashboardView('categories', {
            contactId: event.currentTarget.dataset.id,
            contactName: event.currentTarget.dataset.name
        });
    }

    handleCategoryClick(event) {
        this.navigateDashboardView('assignments', {
            contactId: this.selectedContactId,
            contactName: this.selectedUserName,
            categoryId: event.currentTarget.dataset.id,
            categoryName: event.currentTarget.dataset.name
        });
    }

    async handleOpenAssign(event) {
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
        this.navigateDashboardView('attendance', {
            contactId: event.currentTarget.dataset.contactId,
            contactName: event.currentTarget.dataset.name
        });
    }

    handleBackFromAttendance() {
        this.navigateDashboardView('users', {}, true);
    }

    async handleOpenAssignAssignments(event) {
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

    fetchAssignments(loadRequestId = this.dashboardLoadRequestId) {
        this.isLoading = true;
        getAdminAssignmentsForCategory({ categoryId: this.selectedCategoryId, contactId: this.selectedContactId })
            .then(result => {
                if (loadRequestId !== this.dashboardLoadRequestId) return;
                this.assignments = result.map(assignment => {
                    let assignmentRowClass = 'assignment-row';
                    if (assignment.isCompletedStatus) assignmentRowClass += ' is-completed';
                    if (assignment.isLockedStatus) assignmentRowClass += ' is-locked';
                    return { ...assignment, rowClass: assignmentRowClass };
                });
            })
            .catch(error => {
                if (loadRequestId === this.dashboardLoadRequestId) {
                    this.showToast('Error', error?.body?.message ?? error?.message ?? 'An unexpected error occurred.', 'error');
                }
            })
            .finally(() => {
                if (loadRequestId === this.dashboardLoadRequestId) this.isLoading = false;
            });
    }

    handleViewAttempts(event) {
        this.navigateDashboardView('attempts', {
            contactId: this.selectedContactId,
            contactName: this.selectedUserName,
            categoryId: this.selectedCategoryId,
            categoryName: this.selectedCategoryName,
            assignmentId: event.currentTarget.dataset.id,
            assignmentTitle: event.currentTarget.dataset.title
        });
    }

    loadAttempts(loadRequestId = this.dashboardLoadRequestId) {
        this.isLoading = true;

        getAdminSubmissionAttempts({ assignmentId: this.selectedAssignmentId, contactId: this.selectedContactId })
            .then(result => {
                if (loadRequestId !== this.dashboardLoadRequestId) return;
                this.attempts = result;
            })
            .catch(error => {
                if (loadRequestId === this.dashboardLoadRequestId) {
                    this.showToast('Error', error?.body?.message ?? error?.message ?? 'An unexpected error occurred.', 'error');
                }
            })
            .finally(() => {
                if (loadRequestId === this.dashboardLoadRequestId) this.isLoading = false;
            });
    }

    handleAttemptClick(event) {
        this.navigateDashboardView('review', {
            contactId: this.selectedContactId,
            contactName: this.selectedUserName,
            categoryId: this.selectedCategoryId,
            categoryName: this.selectedCategoryName,
            assignmentId: this.selectedAssignmentId,
            assignmentTitle: this.selectedAssignmentTitle,
            attemptId: event.currentTarget.dataset.id,
            attemptNumber: event.currentTarget.dataset.attempt
        });
    }

    loadAttemptDetail(loadRequestId = this.dashboardLoadRequestId) {
        this.isLoading = true;

        getAdminSubmissionDetail({ submissionId: this.selectedAttemptId })
            .then(result => {
                if (loadRequestId !== this.dashboardLoadRequestId) return;
                this.attemptDetail = result.map((item, attemptIndex) => ({
                    ...item,
                    displayIndex: attemptIndex + 1
                }));
            })
            .catch(error => {
                if (loadRequestId === this.dashboardLoadRequestId) {
                    this.showToast('Error', error?.body?.message ?? error?.message ?? 'An unexpected error occurred.', 'error');
                }
            })
            .finally(() => {
                if (loadRequestId === this.dashboardLoadRequestId) this.isLoading = false;
            });
    }

    navigateBackToUsers() {
        this.navigateDashboardView('users', {}, true);
    }
    navigateBackToCategories() {
        this.navigateDashboardView('categories', {
            contactId: this.selectedContactId,
            contactName: this.selectedUserName
        }, true);
    }
    navigateBackToAssignments() {
        this.navigateDashboardView('assignments', {
            contactId: this.selectedContactId,
            contactName: this.selectedUserName,
            categoryId: this.selectedCategoryId,
            categoryName: this.selectedCategoryName
        }, true);
    }
    navigateBackToAttempts() {
        this.navigateDashboardView('attempts', {
            contactId: this.selectedContactId,
            contactName: this.selectedUserName,
            categoryId: this.selectedCategoryId,
            categoryName: this.selectedCategoryName,
            assignmentId: this.selectedAssignmentId,
            assignmentTitle: this.selectedAssignmentTitle
        }, true);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    get filteredUsers() {
        if (!this.searchTerm) {
            return this.users;
        }
        const term = this.searchTerm.toLowerCase();
        return this.users.filter(user => {
            const name = (user.Name || '').toLowerCase();
            const email = (user.Email || '').toLowerCase();
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