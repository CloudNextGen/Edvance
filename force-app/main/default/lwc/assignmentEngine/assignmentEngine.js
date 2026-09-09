import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getEligibleCategories from '@salesforce/apex/AssignmentService.getEligibleCategories';
import getAssignmentsForCategory from '@salesforce/apex/AssignmentService.getAssignmentsForCategory';
import getAssignmentQuestions from '@salesforce/apex/AssignmentService.getAssignmentQuestions';
import submitAssignment from '@salesforce/apex/AssignmentService.submitAssignment';
import getSubmissionAttempts from '@salesforce/apex/AssignmentService.getSubmissionAttempts';
import getSubmissionDetail from '@salesforce/apex/AssignmentService.getSubmissionDetail';
import getPaginationSettings from '@salesforce/apex/AssignmentService.getPaginationSettings'; // Imported config method
import submitAssessmentFeedback from '@salesforce/apex/AssignmentService.submitAssessmentFeedback';
import submitQuestionFeedback from '@salesforce/apex/AssignmentService.submitQuestionFeedback';
import SVG_RESOURCE from '@salesforce/resourceUrl/Hero_SVG';

// Key used to persist in-progress state across a browser refresh (sessionStorage = tab-scoped, cleared on tab close)
const STATE_KEY = 'sap_engine_state_v1';
const BANNER_AUTOHIDE_MS = 60000; // 1 minute
const NAV_COMPONENT_MATCHERS = ['COMMUNITY_NAVIGATION', 'FORCECOMMUNITY', 'COMM-NAVIGATION'];

export default class AssignmentEngine extends LightningElement {

    backgroundImageUrl = SVG_RESOURCE; 

    @track categories = [];
    @track assignments = [];
    @track questions = [];
    @track attempts = [];
    @track attemptDetail = [];
    @track showExitConfirmation = false;

    selectedCategoryId;
    selectedCategoryName;
    selectedAssignmentId;
    selectedAssignmentTitle;
    selectedAttemptNumber;
    selectedSubmissionId;

    showCategoryScreen = false; // decided synchronously in connectedCallback, not defaulted, to avoid a home-screen flash on refresh
    showAssignmentScreen = false;
    showQuestionScreen = false;
    showAttemptsScreen = false;
    showReviewScreen = false;
    showInstructionsScreen = false;
    countdownSeconds = 5;
    isStartDisabled = true;
    countdownIntervalId = null;
    isRefreshingAssignments = false;
    isAppReady = false; // true once we know which screen to show (either "no saved state" or "restore finished")

    @track answersMap = {};
    isLoading = false;

    // ─── Anti-cheat state ────────────────────────────────────────────────
    tabSwitchCount = 0;
    MAX_TAB_SWITCHES = 3;
    LOCK_REASON = 'Assessment automatically locked after exceeding the maximum allowed tab switches.';
    _violationLock = false;

    // ─── Sticky warning banner state ────────────────────────────────────
    bannerVisible = false;
    bannerTitle = '';
    bannerMessage = '';
    bannerVariant = 'warning';
    bannerTimeoutId = null;

    // ─── Assignment timer state ─────────────────────────────────────────
    selectedAssignmentTimeLimit = null; // minutes, from Assignment__c.Time_Limit_Minutes__c
    quizEndTimestamp = null;            // epoch ms - persisted so refresh keeps the real deadline
    remainingSeconds = null;
    quizTimerIntervalId = null;

    showFeedbackScreen = false;

    // overall (submission-level) feedback
    overallFeedbackComment = '';
    isOverallFeedbackSubmitting = false;
    overallFeedbackSubmitted = false;
    overallFeedbackError;

    // per-question feedback modal
    @track showQuestionFeedbackModal = false;
    feedbackQuestionId;
    feedbackQuestionText = '';
    feedbackQuestionComment = '';
    isQuestionFeedbackSubmitting = false;
    questionFeedbackModalError;
    @track submittedFeedbackQuestionIds = {}; // { [questionId]: true } — drives the checkmark state

    // ─── Dynamic Metadata Pagination State ──────────────────────────────
    assignmentPageSize = 5; // Default fallback
    questionPageSize = 1;   // Default fallback
    
    @track currentAssignmentPage = 1;
    @track currentQuestionPage = 1;

    @track showNavAwayConfirmation = false;
    navAwayCountdownSeconds = 3;
    isNavAwayConfirmDisabled = true;
    navAwayCountdownIntervalId = null;

    connectedCallback() {
        document.addEventListener('visibilitychange', this.handleVisibilityChange);
        window.addEventListener('blur', this.handleWindowBlur);
        window.addEventListener('focus', this.handleWindowFocus);
        document.addEventListener('click', this.handleGlobalNavClick, true);

        // restoreState() returns synchronously: true if valid saved state was found
        // (in which case it kicks off the async reload itself and flips isAppReady
        // when done), false if there's nothing to restore.
        const isRestoring = this.restoreState();
        if (!isRestoring) {
            this.showCategoryScreen = true;
            this.isAppReady = true;
        }
    }
    
    disconnectedCallback() {
        document.removeEventListener('visibilitychange', this.handleVisibilityChange);
        window.removeEventListener('blur', this.handleWindowBlur);
        window.removeEventListener('focus', this.handleWindowFocus);
        document.removeEventListener('click', this.handleGlobalNavClick, true);
        if (this.countdownIntervalId) {
            clearInterval(this.countdownIntervalId);
        }
        this.stopQuizTimer();
        if (this.bannerTimeoutId) {
            clearTimeout(this.bannerTimeoutId);
        }
        if (this.navAwayCountdownIntervalId) {
            clearInterval(this.navAwayCountdownIntervalId);
        }
    }

    get isEmpty() {
        return this.categories.length === 0;
    }

    get feedbackScreenQuestions() {
        return this.questions.map((q) => ({
            ...q,
            feedbackGiven: !!this.submittedFeedbackQuestionIds[q.Id]
        }));
    }

    get navAwayConfirmLabel() {
        return this.isNavAwayConfirmDisabled
            ? `Please wait (${this.navAwayCountdownSeconds}s)`
            : 'Submit & Leave';
    }

    // Fetch config values from Custom Metadata Type
    @wire(getPaginationSettings)
    wiredSettings({ error, data }) {
        if (data) {
            this.assignmentPageSize = data.Assignment_Page_Size__c || 5;
            this.questionPageSize = data.Question_Page_Size__c || 5;
        } else if (error) {
            console.error('Error loading pagination settings metadata:', error);
        }
    }

    // ─── Progress bar style ─────────────────────────────────────────────
    get progressBarStyle() {
        return `width: ${this.completionPercentage}%`;
    }

    get featureBadges() { return this._featureBadges; }

    // ─── Icon + colour cycling for category cards ───────────────────────
    _catIcons = [
        { icon: 'standard:groups',    cls: 'cat-icon cat-icon-0' },
        { icon: 'standard:apex',       cls: 'cat-icon cat-icon-1' },
        { icon: 'standard:knowledge',  cls: 'cat-icon cat-icon-2' },
        { icon: 'standard:dashboard',  cls: 'cat-icon cat-icon-3' },
        { icon: 'standard:flow',       cls: 'cat-icon cat-icon-4' },
        { icon: 'standard:work_order', cls: 'cat-icon cat-icon-5' },
    ];

    _featureBadges = [
        { icon: 'utility:ribbon',   label: 'Quality content',   sub: 'Trusted & curated'      },
        { icon: 'utility:shield',   label: 'AI evaluated',      sub: 'Smart feedback'          },
        { icon: 'utility:trending', label: 'Track progress',    sub: 'Improve continuously'    },
    ];

    get refreshIconClass() {
        return this.isRefreshingAssignments ? 'refresh-icon spinning' : 'refresh-icon';
    }

    @wire(getEligibleCategories)
    wiredCategories({ error, data }) {
        if (data) {
            this.categories = data.map((cat, idx) => ({
                ...cat,
                iconName:    this._catIcons[idx % this._catIcons.length].icon,
                iconClass:   this._catIcons[idx % this._catIcons.length].cls,
                cardClass:   `cat-card cat-accent-${idx % this._catIcons.length}`,
                description: 'Assess knowledge and skills across this subject area.'
            }));
        } else if (error) {
            console.error(error);
        }
    }

    handleCategoryClick(event) {
        this.selectedCategoryId = event.currentTarget.dataset.id;
        this.selectedCategoryName = event.currentTarget.dataset.name;
    
        this.loadAssignments()
            .then(() => {
                this.currentAssignmentPage = 1;
                this.showCategoryScreen = false;
                this.showAssignmentScreen = true;
                this.persistState();
            });
    }
    
    loadAssignments() {
        return getAssignmentsForCategory({ categoryId: this.selectedCategoryId })
            .then(result => {
                this.assignments = result.map(asm => ({
                    ...asm,
                    isEligibleStatus:  asm.status === 'Eligible',
                    isCompletedStatus: asm.status === 'Completed',
                    isLockedStatus:    asm.status === 'Locked'
                }));
            })
            .catch(error => {
                console.error(error);
                this.showToast('Error', 'Could not load assignments. Please try again.', 'error');
            });
    }
    
    handleRefreshAssignments() {
        this.isRefreshingAssignments = true;
    
        this.loadAssignments()
            .then(() => {
                const maxPage = Math.max(1, Math.ceil(this.assignments.length / this.assignmentPageSize) || 1);
                if (this.currentAssignmentPage > maxPage) {
                    this.currentAssignmentPage = maxPage;
                }
                this.showToast('Refreshed', 'Assignment list has been updated.', 'success');
            })
            .finally(() => {
                this.isRefreshingAssignments = false;
            });
    }

    handleAssignmentClick(event) {
        const asmId = event.target.dataset.id;
        const asm = this.assignments.find(a => a.Id === asmId);
        if (!asm || !asm.isEligibleStatus) {
            this.handleRefreshAssignments(); // silent — no toast, just resync the list
            return;
        }
        this.selectedAssignmentId = asmId;
        this.selectedAssignmentTitle = event.target.dataset.title;

        this.tabSwitchCount = 0;

        getAssignmentQuestions({ assignmentId: this.selectedAssignmentId })
            .then(result => {
                this.questions = result.map((question, index) => ({
                    ...question,
                    displayIndex: index + 1,
                    isAnswered: false
                }));
                this.answersMap  = {};
                this.currentQuestionPage = 1; // Reset question view to page 1
                this.showAssignmentScreen = false;
                this.showInstructionsScreen = true;
                this.startCountdown();
                this.persistState();
            })
            .catch(error => console.error(error));
    }

    startCountdown() {
        this.countdownSeconds = 5;
        this.isStartDisabled = true;
    
        if (this.countdownIntervalId) {
            clearInterval(this.countdownIntervalId);
        }
    
        this.countdownIntervalId = setInterval(() => {
            this.countdownSeconds -= 1;
            if (this.countdownSeconds <= 0) {
                clearInterval(this.countdownIntervalId);
                this.countdownIntervalId = null;
                this.isStartDisabled = false;
            }
        }, 1000);
    }
    
    get startButtonLabel() {
        return this.isStartDisabled
            ? `Please wait (${this.countdownSeconds}s)`
            : 'Start Assessment →';
    }
    
    handleBeginAssessment() {
        this.showInstructionsScreen = false;
        this.showQuestionScreen = true;
        this.startQuizTimer();
        this.persistState();
    }
    
    navBackFromInstructions() {
        if (this.countdownIntervalId) {
            clearInterval(this.countdownIntervalId);
            this.countdownIntervalId = null;
        }
        this.showInstructionsScreen = false;
        this.showAssignmentScreen   = true;
        this.persistState();
    }

    // Completed row click → list of past attempts
    handleViewAttempts(event) {
        this.selectedAssignmentId    = event.currentTarget.dataset.id;
        this.selectedAssignmentTitle = event.currentTarget.dataset.title;

        return getSubmissionAttempts({ assignmentId: this.selectedAssignmentId })
        .then(result => {
            this.attempts = result.map(a => {
                const isPass = a.Pass_Fail_Status__c === 'Pass';
                const isGraded = a.Status__c === 'Graded';

                // Determine the badge look based on whether it's graded or pending
                let badgeLabel = a.Status__c || 'Pending';
                let badgeClass = 'status-badge badge-pending';

                if (isGraded) {
                    badgeLabel = isPass ? 'Pass' : 'Fail';
                    badgeClass = isPass ? 'status-badge badge-pass' : 'status-badge badge-fail';
                }
                if(a.Is_Locked__c){
                    badgeLabel = 'Fail';
                    badgeClass = 'status-badge badge-fail';

                }

                return {
                    ...a,
                    scoreLabel: `${a.Score_Received__c || 0} / ${a.Max_Score__c || 0}`,
                    passFailLabel: badgeLabel,
                    passFailClass: badgeClass,
                    isLocked: a.Is_Locked__c,
                    lockReason: a.Lock_Reason__c
                };
            });
            
            this.showAssignmentScreen = false;
            this.showAttemptsScreen   = true;
            this.persistState();
        })
        .catch(error => console.error(error));
    }

    // Attempt row click → read-only question/answer/score view
    handleAttemptClick(event) {
        const submissionId = event.currentTarget.dataset.id;
        this.selectedSubmissionId = submissionId;
        this.selectedAttemptNumber = event.currentTarget.dataset.attempt;

        getSubmissionDetail({ submissionId })
            .then(result => {
                this.attemptDetail = result.map((q, index) => ({
                    ...q,
                    displayIndex: index + 1
                }));
                this.showAttemptsScreen = false;
                this.showReviewScreen   = true;
            })
            .catch(error => console.error(error));
    }

    handleTextChange(event) {
        const questionId = event.target.dataset.id;
        const answerText = event.target.value.trim();

        const updatedMap = { ...this.answersMap };
        if (answerText.length > 0) {
            updatedMap[questionId] = answerText;
        } else {
            delete updatedMap[questionId];
        }
        this.answersMap = updatedMap;

        this.questions = this.questions.map(q => {
            if (q.Id === questionId) {
                return { ...q, isAnswered: answerText.length > 0 };
            }
            return q;
        });

        this.persistState();
    }

    // ─── Anti-cheat: block paste / copy on the answer textarea ──────────
    handlePasteBlock(event) {
        event.preventDefault();
        this.showToast('Pasting disabled', 'Please type your answer instead of pasting.', 'warning');
    }

    handleCopyBlock(event) {
        event.preventDefault();
    }

    handleVisibilityChange = () => {
        if (document.hidden && this.showQuestionScreen) {
            this.registerViolation();
        }
    };
    
    handleWindowBlur = () => {
        if (this.showQuestionScreen) {
            this.registerViolation();
        }
    };
    
    handleWindowFocus = () => {
        this._violationLock = false;
    };
    
    registerViolation() {
        if (this._violationLock) {
            return;
        }
        this._violationLock = true;
        this.handleTabViolation();
    }

    // ─── Assignment Pagination Logic ────────────────────────────────────
    get totalAssignmentPages() {
        return Math.ceil(this.assignments.length / this.assignmentPageSize) || 1;
    }

    get isFirstAssignmentPage() { return this.currentAssignmentPage === 1; }
    get isLastAssignmentPage()  { return this.currentAssignmentPage === this.totalAssignmentPages; }

    get paginatedAssignments() {
        const start = (this.currentAssignmentPage - 1) * this.assignmentPageSize;
        const end   = start + this.assignmentPageSize;
        return this.assignments.slice(start, end);
    }

    get assignmentPageIndicatorLabel() {
        return `Page ${this.currentAssignmentPage} of ${this.totalAssignmentPages}`;
    }

    handleNextAssignmentPage() {
        if (!this.isLastAssignmentPage) {
            this.currentAssignmentPage += 1;
            this.persistState();
        }
    }
    handlePrevAssignmentPage() {
        if (!this.isFirstAssignmentPage) {
            this.currentAssignmentPage -= 1;
            this.persistState();
        }
    }


    // ─── Question Pagination Logic ──────────────────────────────────────
    get totalQuestionPages() {
        return Math.ceil(this.questions.length / this.questionPageSize) || 1;
    }

    get isFirstQuestionPage() { return this.currentQuestionPage === 1; }
    get isLastQuestionPage()  { return this.currentQuestionPage === this.totalQuestionPages; }

    get paginatedQuestions() {
        const start = (this.currentQuestionPage - 1) * this.questionPageSize;
        const end   = start + this.questionPageSize;
        return this.questions.slice(start, end).map(q => ({
            ...q,
            savedAnswer: this.answersMap[q.Id] || '',
            statusDotClass: this.answersMap[q.Id] ? 'status-dot status-dot-done' : 'status-dot status-dot-pending'
        }));
    }

    get questionPageIndicatorLabel() {
        return `Page ${this.currentQuestionPage} of ${this.totalQuestionPages}`;
    }

    handleNextQuestionPage() {
        if (!this.isLastQuestionPage) {
            this.currentQuestionPage += 1;
            this.persistState();
        }
    }
    handlePrevQuestionPage() {
        if (!this.isFirstQuestionPage) {
            this.currentQuestionPage -= 1;
            this.persistState();
        }
    }


    // ─── Progress ───────────────────────────────────────────────────────
    get answeredCount()      { return Object.keys(this.answersMap).length; }
    get totalQuestionsCount(){ return this.questions.length; }
    get completionPercentage() {
        if (this.totalQuestionsCount === 0) return 0;
        return Math.round((this.answeredCount / this.totalQuestionsCount) * 100);
    }

    // ─── Navigation ─────────────────────────────────────────────────────
    navBackToCategories() {
        this.showAssignmentScreen = false;
        this.showCategoryScreen   = true;
        this.clearPersistedState();
    }

    handleExitAssessment() {
        this.showExitConfirmation = true;
    }

    navBackToAssignments() {
        this.showQuestionFeedbackModal = false;
        this.showQuestionScreen = false;
        this.showAttemptsScreen = false;
        this.showReviewScreen = false;
        this.showAssignmentScreen = true;
        this.stopQuizTimer();
        this.persistState();
    }

    handleCancelExit() {
        this.showExitConfirmation = false;
    }

    // Exiting mid-assessment now submits whatever has been answered so far,
    // rather than discarding it and allowing a free re-attempt.
    handleConfirmExit() {
        this.showExitConfirmation = false;
        this.isLoading = true;

        submitAssignment({
            assignmentId: this.selectedAssignmentId,
            answersJson: JSON.stringify(this.answersMap),
            isLocked: false,
            lockReason: '',
            violationCount: this.tabSwitchCount
        })
            .then((submissionId) => {
                this.selectedSubmissionId = submissionId;
                this.showToast(
                    'Assignment Submitted',
                    'You exited the assessment, so your current answers were submitted for AI grading.',
                    'warning'
                );
                this.resetQuizState();
            })
            .catch(error => {
                this.showToast('Submission Error', error.body.message, 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    navBackToAttempts() {
        this.showQuestionFeedbackModal = false;
        this.showReviewScreen   = false;
        this.showAttemptsScreen = true;
        this.persistState();
    }

    handleTabViolation() {

        if (this.isLoading) {
            return;
        }
        
        this.tabSwitchCount++;
        this.persistState();
    
        if (this.tabSwitchCount === 1) {
            this.showWarningBanner(
                'Tab Switching Detected',
                'Tab switching is not allowed during this assessment. Warning 1 of 3. After 3 violations your assignment will be automatically submitted and marked as Failed.',
                'warning'
            );
        }
        else if (this.tabSwitchCount === 2) {
            this.showWarningBanner(
                'Final Warning',
                'Warning 2 of 3. One more tab switch will automatically submit and lock this assessment. This attempt will be marked as Failed.',
                'critical'
            );
        }
        else if (this.tabSwitchCount >= this.MAX_TAB_SWITCHES) {
            this.autoSubmitLockedAssignment();
        }
    }

    // ─── Sticky warning banner (stays open until closed, capped at 1 minute) ──
    showWarningBanner(title, message, variant = 'warning') {
        if (this.bannerTimeoutId) {
            clearTimeout(this.bannerTimeoutId);
        }
        this.bannerTitle = title;
        this.bannerMessage = message;
        this.bannerVariant = variant;
        this.bannerVisible = true;

        this.bannerTimeoutId = setTimeout(() => {
            this.bannerVisible = false;
            this.bannerTimeoutId = null;
        }, BANNER_AUTOHIDE_MS);
    }

    handleCloseBanner() {
        if (this.bannerTimeoutId) {
            clearTimeout(this.bannerTimeoutId);
            this.bannerTimeoutId = null;
        }
        this.bannerVisible = false;
    }

    get bannerClass() {
        return `violation-banner violation-banner-${this.bannerVariant}`;
    }

    // ─── Assignment timer ────────────────────────────────────────────────
    // Reads Time_Limit_Minutes__c off the assignment record already loaded
    // in this.assignments. Leave that field blank/0 on the record for an
    // untimed assignment.
    startQuizTimer() {
        const asm = this.assignments.find(a => a.Id === this.selectedAssignmentId);
        const minutes = asm ? asm.Time_Limit_Minutes__c : null;
        this.selectedAssignmentTimeLimit = minutes;

        if (!minutes || minutes <= 0) {
            this.quizEndTimestamp = null;
            this.remainingSeconds = null;
            return;
        }

        this.quizEndTimestamp = Date.now() + (minutes * 60 * 1000);
        this.runQuizTimer();
    }

    // Used when restoring after a refresh: recompute remaining time from the
    // persisted absolute end-timestamp rather than restarting the clock.
    resumeQuizTimer() {
        if (!this.quizEndTimestamp) {
            return;
        }
        const asm = this.assignments.find(a => a.Id === this.selectedAssignmentId);
        this.selectedAssignmentTimeLimit = asm ? asm.Time_Limit_Minutes__c : null;
        this.runQuizTimer();
    }

    runQuizTimer() {
        if (this.quizTimerIntervalId) {
            clearInterval(this.quizTimerIntervalId);
            this.quizTimerIntervalId = null;
        }
        if (!this.quizEndTimestamp) {
            return;
        }

        const tick = () => {
            const remainingMs = this.quizEndTimestamp - Date.now();
            if (remainingMs <= 0) {
                this.remainingSeconds = 0;
                clearInterval(this.quizTimerIntervalId);
                this.quizTimerIntervalId = null;
                this.handleTimeExpired();
                return;
            }
            this.remainingSeconds = Math.ceil(remainingMs / 1000);
        };

        tick();
        this.quizTimerIntervalId = setInterval(tick, 1000);
    }

    stopQuizTimer() {
        if (this.quizTimerIntervalId) {
            clearInterval(this.quizTimerIntervalId);
            this.quizTimerIntervalId = null;
        }
        this.quizEndTimestamp = null;
        this.remainingSeconds = null;
    }

    handleTimeExpired() {
        this.showToast(
            "Time's Up",
            'The time limit for this assessment has been reached. Submitting your answers now.',
            'warning'
        );
        this.handleSubmitVerification();
    }

    get showTimer() {
        return this.quizEndTimestamp != null;
    }

    get timerDisplay() {
        if (this.remainingSeconds == null) return '';
        const m = Math.floor(this.remainingSeconds / 60);
        const s = this.remainingSeconds % 60;
        return `${m}:${s < 10 ? '0' : ''}${s}`;
    }

    get timerClass() {
        return this.remainingSeconds != null && this.remainingSeconds <= 60
            ? 'quiz-timer quiz-timer-critical'
            : 'quiz-timer';
    }

    // ─── Submit ─────────────────────────────────────────────────────────
    handleSubmitVerification() {
        this.isLoading = true;
        this.stopQuizTimer();

        const payloadStr = JSON.stringify(this.answersMap);

        submitAssignment({
            assignmentId: this.selectedAssignmentId,
            answersJson:  payloadStr,
            isLocked: false,
            lockReason: '',
            violationCount: 0
        })
            .then((submissionId) => {
                this.selectedSubmissionId = submissionId;
                this.showToast(
                    'Assignment Submitted!',
                    'Your attempt has been safely recorded. The AI-grading pipeline is now processing your scores.',
                    'success'
                );
                this.resetQuizState();
            })
            .catch(error => {
                this.showToast('Submission Error', error.body.message, 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    autoSubmitLockedAssignment() {

        if (this.isLoading) {
            return;
        }

        this.isLoading = true;
        this.stopQuizTimer();
    
        submitAssignment({
            assignmentId: this.selectedAssignmentId,
            answersJson: JSON.stringify(this.answersMap),
            isLocked: true,
            lockReason: this.LOCK_REASON,
            violationCount: this.tabSwitchCount
        })
        .then((submissionId) => {
            this.selectedSubmissionId = submissionId;
            this.showToast(
                'Assessment Locked',
                'Your assessment has been automatically submitted because the maximum number of tab-switch violations was reached.',
                'error'
            );
    
            this.resetQuizState();
        })
        .catch(error => {
            this.showToast(
                'Submission Error',
                error.body.message,
                'error'
            );
        })
        .finally(() => {
            this.isLoading = false;
        });
    }

    // Shared cleanup after any terminal
    //  action (normal submit, exit-submit, lock-submit)
    resetQuizState() {
        this.showQuestionFeedbackModal = false;
        this.stopQuizTimer();
        this.answersMap = {};
        this.tabSwitchCount = 0;
        this.currentQuestionPage = 1;
        this.showQuestionScreen = false;
        this.showAttemptsScreen = false;
        this.showReviewScreen = false;
        this.showAssignmentScreen = false;

        // reset feedback screen state for this fresh submission
        this.overallFeedbackComment = '';
        this.overallFeedbackSubmitted = false;
        this.overallFeedbackError = undefined;
        this.submittedFeedbackQuestionIds = {};

        this.showFeedbackScreen = true;
        this.clearPersistedState();
    }

    // ─── Overall (per-submission) feedback ───────────────────────────────
    handleOverallFeedbackCommentChange(event) {
        this.overallFeedbackComment = event.target.value;
    }

    handleOverallFeedbackSubmit() {
        if (!this.overallFeedbackComment || !this.overallFeedbackComment.trim()) {
            this.overallFeedbackError = 'Please enter a comment.';
            return;
        }
        if (!this.selectedSubmissionId) {
            this.overallFeedbackError = 'Unable to attach feedback to this submission.';
            return;
        }

        this.isOverallFeedbackSubmitting = true;
        submitAssessmentFeedback({ submissionId: this.selectedSubmissionId, commentText: this.overallFeedbackComment })
            .then(() => {
                this.overallFeedbackSubmitted = true;
                this.overallFeedbackError = undefined;
                this.showToast('Feedback submitted', 'Thanks — your feedback has been sent.', 'success');
            })
            .catch((error) => {
                this.overallFeedbackError = error.body ? error.body.message : error.message;
            })
            .finally(() => {
                this.isOverallFeedbackSubmitting = false;
            });
    }

    // ─── Per-question feedback ────────────────────────────────────────────
    handleQuestionFeedbackIconClick(event) {
        const questionId = event.currentTarget.dataset.id;
        const question = this.questions.find((q) => q.Id === questionId);
        this.feedbackQuestionId = questionId;
        this.feedbackQuestionText = question ? question.Question_Text__c : '';
        this.feedbackQuestionComment = '';
        this.questionFeedbackModalError = undefined;
        this.showQuestionFeedbackModal = true;
    }

    handleQuestionFeedbackCommentChange(event) {
        this.feedbackQuestionComment = event.target.value;
    }

    handleQuestionFeedbackCancel() {
        this.showQuestionFeedbackModal = false;
        this.feedbackQuestionId = undefined;
    }

    stopPropagation(event) {
        event.stopPropagation();
    }

    handleQuestionFeedbackSubmit() {
        if (!this.feedbackQuestionComment || !this.feedbackQuestionComment.trim()) {
            this.questionFeedbackModalError = 'Please enter a comment.';
            return;
        }

        this.isQuestionFeedbackSubmitting = true;
        submitQuestionFeedback({ assignmentQuestionId: this.feedbackQuestionId, commentText: this.feedbackQuestionComment })
            .then(() => {
                this.submittedFeedbackQuestionIds = { ...this.submittedFeedbackQuestionIds, [this.feedbackQuestionId]: true };
                this.showQuestionFeedbackModal = false;
                this.feedbackQuestionId = undefined;
                this.feedbackQuestionComment = '';
                this.showToast('Feedback submitted', 'Thanks for the feedback on this question.', 'success');
            })
            .catch((error) => {
                this.questionFeedbackModalError = error.body ? error.body.message : error.message;
            })
            .finally(() => {
                this.isQuestionFeedbackSubmitting = false;
            });
    }

    handleFeedbackScreenDone() {
        this.showFeedbackScreen = false;
        this.selectedSubmissionId = undefined;
        this.loadAssignments().finally(() => {
        this.showAssignmentScreen = true;
    });
    }

    // ─── Refresh persistence ─────────────────────────────────────────────
    // Saves just enough state to sessionStorage (tab-scoped, survives a
    // refresh, clears when the tab closes) so a refresh can drop the user
    // back on the same screen instead of the category home screen.
    get currentScreenKey() {
        if (this.showQuestionScreen) return 'question';
        if (this.showInstructionsScreen) return 'instructions';
        if (this.showAssignmentScreen) return 'assignment';
        if (this.showAttemptsScreen) return 'attempts';
        if (this.showReviewScreen) return 'review';
        if (this.showFeedbackScreen) return 'feedback';
        return 'category';
    }

    persistState() {
        const screen = this.currentScreenKey;
        if (screen === 'category') {
            this.clearPersistedState();
            return;
        }

        const state = {
            screen,
            selectedCategoryId: this.selectedCategoryId,
            selectedCategoryName: this.selectedCategoryName,
            selectedAssignmentId: this.selectedAssignmentId,
            selectedAssignmentTitle: this.selectedAssignmentTitle,
            answersMap: this.answersMap,
            currentQuestionPage: this.currentQuestionPage,
            currentAssignmentPage: this.currentAssignmentPage,
            tabSwitchCount: this.tabSwitchCount,
            quizEndTimestamp: this.quizEndTimestamp
        };

        try {
            sessionStorage.setItem(STATE_KEY, JSON.stringify(state));
        } catch (e) {
            // sessionStorage unavailable (private browsing, etc.) - fail silently, refresh just falls back to home
        }
    }

    clearPersistedState() {
        try {
            sessionStorage.removeItem(STATE_KEY);
        } catch (e) {
            // ignore
        }
    }

    restoreState() {
        let raw;
        try {
            raw = sessionStorage.getItem(STATE_KEY);
        } catch (e) {
            return false;
        }
        if (!raw) return false;

        let state;
        try {
            state = JSON.parse(raw);
        } catch (e) {
            return false;
        }
        if (!state || !state.screen || state.screen === 'category' || !state.selectedCategoryId) {
            return false;
        }

        this.isRestoringState = true;
        this.selectedCategoryId = state.selectedCategoryId;
        this.selectedCategoryName = state.selectedCategoryName;
        this.selectedAssignmentId = state.selectedAssignmentId;
        this.selectedAssignmentTitle = state.selectedAssignmentTitle;
        this.answersMap = state.answersMap || {};
        this.currentQuestionPage = state.currentQuestionPage || 1;
        this.currentAssignmentPage = state.currentAssignmentPage || 1;
        this.tabSwitchCount = state.tabSwitchCount || 0;
        this.quizEndTimestamp = state.quizEndTimestamp || null;

        this.loadAssignments()
            .then(() => {
                if (state.screen === 'assignment') {
                    this.showCategoryScreen = false;
                    this.showAssignmentScreen = true;
                    this.isRestoringState = false;
                    this.isAppReady = true;
                    return true;
                }

                if (state.screen === 'attempts') {
                    this.handleViewAttempts({
                        currentTarget: { dataset: { id: this.selectedAssignmentId, title: this.selectedAssignmentTitle } }
                    }).finally(() => {
                        this.isRestoringState = false;
                        this.isAppReady = true;
                    });
                    return false;
                }

                if ((state.screen === 'instructions' || state.screen === 'question') && this.selectedAssignmentId) {
                    getAssignmentQuestions({ assignmentId: this.selectedAssignmentId })
                        .then(result => {
                            this.questions = result.map((q, idx) => ({
                                ...q,
                                displayIndex: idx + 1,
                                isAnswered: !!this.answersMap[q.Id]
                            }));
                            this.showCategoryScreen = false;

                            if (state.screen === 'question') {
                                this.showQuestionScreen = true;
                                this.resumeQuizTimer();
                            } else {
                                this.showInstructionsScreen = true;
                                this.startCountdown();
                            }
                        })
                        .catch(error => {
                            console.error(error);
                            return false;
                        })
                        .finally(() => {
                            this.isRestoringState = false;
                            this.isAppReady = true;
                        });
                    return true;
                }

                this.isRestoringState = false;
                this.isAppReady = true;
            })
            .catch(() => {
                this.isRestoringState = false;
                this.isAppReady = true;
            });

        return true;
    }

    handleGlobalNavClick = (event) => {
        if (this._bypassNavIntercept) {
            this._bypassNavIntercept = false;
            return;
        }

        const savedStateRaw = sessionStorage.getItem(STATE_KEY);
        const savedState = savedStateRaw ? JSON.parse(savedStateRaw) : null;
        const isQuizActive = this.showQuestionScreen || (savedState && savedState.screen === 'question');
        if (!isQuizActive) {
            return;
        }

        const path = event.composedPath();
        const hostMatch = path.includes(this.template.host);
        if (hostMatch) {
            return;
        }

        const navTarget = path.find(el => {
            if (!el || !el.tagName) return false;
            const tag = el.tagName.toUpperCase();
            const isAnchor = tag === 'A';
            const isKnownNavComponent = NAV_COMPONENT_MATCHERS.some(m => tag.includes(m));
            const href = el.getAttribute ? (el.getAttribute('href') || '') : '';
            return isAnchor || isKnownNavComponent || (href.length > 0 && !href.startsWith('javascript:'));
        });

        if (navTarget) {
            event.preventDefault();
            event.stopPropagation();
            this._pendingNavElement = navTarget;
            this.showNavAwayConfirmation = true;
            this.startNavAwayCountdown();
        }
    };

    startNavAwayCountdown() {
        this.navAwayCountdownSeconds = 3;
        this.isNavAwayConfirmDisabled = true;

        if (this.navAwayCountdownIntervalId) {
            clearInterval(this.navAwayCountdownIntervalId);
        }

        this.navAwayCountdownIntervalId = setInterval(() => {
            this.navAwayCountdownSeconds -= 1;
            if (this.navAwayCountdownSeconds <= 0) {
                clearInterval(this.navAwayCountdownIntervalId);
                this.navAwayCountdownIntervalId = null;
                this.isNavAwayConfirmDisabled = false;
            }
        }, 1000);
    }

    handleConfirmNavAway() {
        this.showNavAwayConfirmation = false;
        this.isLoading = true;
        submitAssignment({
            assignmentId: this.selectedAssignmentId,
            answersJson: JSON.stringify(this.answersMap),
            isLocked: false,
            lockReason: '',
            violationCount: this.tabSwitchCount
        })
            .then(() => {
                this.resetQuizState();
                this._bypassNavIntercept = true;
                this._pendingNavElement.click(); // replay it for real this time
                this._pendingNavElement = null;
            })
            .catch(error => {
                this.showToast('Submission Error', error?.body?.message || 'Could not submit your assessment.', 'error');
            })
            .finally(() => { this.isLoading = false; });
    }

    handleCancelNavAway() {
        if (this.navAwayCountdownIntervalId) {
            clearInterval(this.navAwayCountdownIntervalId);
            this.navAwayCountdownIntervalId = null;
        }
        this.showNavAwayConfirmation = false;
    }
}