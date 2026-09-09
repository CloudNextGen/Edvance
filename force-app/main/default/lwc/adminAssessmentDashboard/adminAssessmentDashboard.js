import { LightningElement, track, wire } from 'lwc';
import getExperienceUsers from '@salesforce/apex/AdminDashboardController.getExperienceUsers';
import getCategories from '@salesforce/apex/AdminDashboardController.getCategories';
import getAdminAssignmentsForCategory from '@salesforce/apex/AdminDashboardController.getAdminAssignmentsForCategory';
import getAdminSubmissionAttempts from '@salesforce/apex/AdminDashboardController.getAdminSubmissionAttempts';
import getAdminSubmissionDetail from '@salesforce/apex/AdminDashboardController.getAdminSubmissionDetail';
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

    searchTerm = '';

    // Screen Toggles
    showUserScreen = true;
    showCategoryScreen = false;
    showAssignmentScreen = false;
    showAttemptsScreen = false;
    showReviewScreen = false;
    isLoading = false;

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

    showCreateUserModal = false;

    get showCreateUserLink() { return canViewAttendance; }

    handleOpenCreateUser() {
        this.showCreateUserModal = true;
    }

    handleCloseCreateUser() {
        this.showCreateUserModal = false;
    }

    handleCreateUserSuccess() {
        this.showCreateUserModal = false;
        this.showToast('Success', 'User created.', 'success');
    }

    get showAssignmentsLink() { return canViewAssignments; }
    get showAssignFilesLink() { return canAssignFiles; }
    get showAttendanceLink() { return canViewAttendance; }

    @wire(getExperienceUsers)
    wiredUsers({ error, data }) {
        if (data) this.users = data;
        else if (error) this.showToast('Error', 'Failed to retrieve active roster profiles.', 'error');
    }

    // getCategories() doesn't depend on contactId/any per-user state, so it's
    // wired once at load instead of being re-fetched imperatively on every click.
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
        event.stopPropagation(); // prevents handleUserClick from also firing
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

    // Navigations back
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