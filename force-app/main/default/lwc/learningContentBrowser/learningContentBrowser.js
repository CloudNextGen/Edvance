import { LightningElement, track } from 'lwc';
import getLearningContentTree from '@salesforce/apex/LearningContentController.getLearningContentTree';
import markFileComplete from '@salesforce/apex/LearningContentController.markFileComplete';
import recordFileOpened from '@salesforce/apex/LearningContentController.recordFileOpened';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import submitFileFeedback from '@salesforce/apex/LearningContentController.submitFileFeedback';
import requestNextContentAccess from '@salesforce/apex/LearningContentController.requestNextContentAccess';
import getNextContentAccessRequestStatus from '@salesforce/apex/LearningContentController.getNextContentAccessRequestStatus';
import HERO2_SVG from '@salesforce/resourceUrl/Hero2_SVG';

export default class LearningContentBrowser extends LightningElement {

    backgroundImageUrl = HERO2_SVG;

    @track rootFolders = [];
    @track breadcrumbs = [];
    @track currentFolder = undefined; // Explicitly tracked for UI reactive deep changes
    @track showFeedbackModal = false;
    feedbackFileId;
    feedbackFileName = '';
    feedbackComment = '';
    isFeedbackSubmitting = false;
    feedbackModalError;
    isAccessRequestSubmitting = false;
    isNextContentRequestAvailable = false;
    accessRequestSent = false;
    accessRequestNotificationSent = false;
    accessRequestWasCreated = false;
    accessRequestStatus;
    accessRequestCanNotifyAgain = false;
    accessRequestFolderId;
    isCheckingAccessRequest = false;
    now = Date.now(); // Ticks every 500ms; drives the timer countdown reactively
    error;
    isLoading = true;
    timerInterval = null;
    // Temporary client-side flag set when the server reports the next
    // folder was unlocked. This helps avoid a brief reload/race where the
    // UI hasn't yet observed the newly-created access record.
    _nextFolderUnlockedPending = false;

    connectedCallback() {
        this.restoreNavigationState();
        this.loadTree();
        this.startTimerLoop();
    }

    disconnectedCallback() {
        if (this.timerInterval) {
            clearInterval(this.timerInterval);
        }
    }

    startTimerLoop() {
        if (this.timerInterval) {
            clearInterval(this.timerInterval);
        }
        this.timerInterval = setInterval(() => {
            this.now = Date.now();
        }, 500);
    }

    loadTree() {
        this.isLoading = true;

        // Return the promise so callers can wait for the refreshed tree
        return getLearningContentTree()
            .then((data) => {
                this.rootFolders = data;
                this.error = undefined;

                // ─── Re-sync currentFolder into the freshly loaded tree ──────
                // rootFolders is a brand new object graph on every load, so any
                // existing currentFolder reference is stale and must be
                // re-resolved by id via the breadcrumb trail, or newly granted
                // files/updated statuses will never show up in the UI.
                if (this.breadcrumbs.length > 0) {
                    const targetId = this.breadcrumbs[this.breadcrumbs.length - 1].id;
                    const restoredFolder = this.findFolderById(this.rootFolders, targetId);
                    if (restoredFolder) {
                        this.currentFolder = restoredFolder;
                    } else {
                        this.breadcrumbs = [];
                        this.currentFolder = undefined;
                    }
                } else {
                    this.currentFolder = undefined;
                }

                this.persistNavigationState();
                this.loadAccessRequestStatus();
            })
            .catch((error) => {
                this.error = error.body ? error.body.message : error.message;
                this.rootFolders = [];
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    _catAccents = ['cat-accent-0', 'cat-accent-1', 'cat-accent-2', 'cat-accent-3', 'cat-accent-4', 'cat-accent-5'];
    // NOTE: this is intentionally a single value, not an array like _catAccents above.
    // Every folder currently renders with this same icon; only the accent color cycles
    // per folder (see displayFolders below). Renamed from `_catIcons` to make that
    // singular/non-cycling intent explicit at a glance.
    DEFAULT_FOLDER_ICON = 'standard:folder';

    get itemsToShow() {
        const folders = this.currentFolder ? this.currentFolder.subFolders : this.rootFolders;
        const files = this.currentFolder ? this.currentFolder.files : [];
        return {
            folders: folders || [],
            files: files || [],
            hasFolders: folders && folders.length > 0,
            hasFiles: files && files.length > 0
        };
    }

    get isEmpty() {
        return !this.isLoading && !this.error && !this.itemsToShow.hasFolders && !this.itemsToShow.hasFiles;
    }

    get isAccessRestricted() {
        const message = (this.error || '').toLowerCase();
        return message.includes('team member') && message.includes('files and assignments');
    }

    get showRootHero() {
        return this.breadcrumbs.length === 0;
    }

    get showBackBar() {
        return this.breadcrumbs.length > 0;
    }

    naturalCompare(firstName, secondName) {
        return String(firstName).localeCompare(String(secondName), undefined, { numeric: true, sensitivity: 'base' });
    }

    // Sort by Sort_Order__c first (nulls last), falling back to natural name compare
    sortBySortOrderThenName(list) {
        return [...list].sort((firstItem, secondItem) => {
            const firstSortOrder = firstItem.sortOrder;
            const secondSortOrder = secondItem.sortOrder;
            if (firstSortOrder != null && secondSortOrder != null && firstSortOrder !== secondSortOrder) {
                return firstSortOrder - secondSortOrder;
            }
            if (firstSortOrder != null && secondSortOrder == null) return -1;
            if (firstSortOrder == null && secondSortOrder != null) return 1;
            return this.naturalCompare(firstItem.name, secondItem.name);
        });
    }

    // Pluralizes a count + noun pair, e.g. (1, 'folder') -> '1 folder', (2, 'folder') -> '2 folders'
    pluralize(count, noun) {
        const safeCount = count || 0;
        return `${safeCount} ${noun}${safeCount === 1 ? '' : 's'}`;
    }

    get displayFolders() {
        return this.sortBySortOrderThenName(this.itemsToShow.folders)
            .map((folder, folderIndex) => {
                const subCount = folder.subFolders ? folder.subFolders.length : 0;
                const fileCount = folder.files ? folder.files.length : 0;
                return {
                    ...folder,
                    cardClass: `lc-folder-card ${this._catAccents[folderIndex % this._catAccents.length]}`,
                    iconName: this.DEFAULT_FOLDER_ICON,
                    iconClass: `lc-folder-icon lc-icon-${folderIndex % this._catAccents.length}`,
                    fileCount,
                    subCount,
                    countsLabel: `${this.pluralize(subCount, 'folder')} · ${this.pluralize(fileCount, 'file')}`
                };
            });
    }

    get displayFiles() {
        return this.sortBySortOrderThenName(this.itemsToShow.files)
            .map((learningFile) => {
                const isCompleted = learningFile.completionStatus === 'Completed';
                const hasBeenOpened = learningFile.dateTimeOpened != null;
                const isAccessRevoked = learningFile.accessRevoked === true;

                // Compute remaining time directly from `now`, no separate cache
                // to fall out of sync or default to 0 during a render race.
                let remainingSeconds = 0;
                const parsedMinutes = Number(learningFile.estimatedTimeMinutes);
                const durationSeconds = Number.isFinite(parsedMinutes) && parsedMinutes > 0 ? parsedMinutes * 60 : 0;

                if (hasBeenOpened && durationSeconds > 0) {
                    const openedTime = Date.parse(learningFile.dateTimeOpened);
                    if (Number.isFinite(openedTime)) {
                        const elapsedSeconds = Math.floor((this.now - openedTime) / 1000);
                        remainingSeconds = Math.max(0, durationSeconds - elapsedSeconds);
                    }
                }

                // If opened but no estimated time was ever set, treat as expired immediately
                const timeExpired = !isAccessRevoked && hasBeenOpened &&
                    (!learningFile.estimatedTimeMinutes || remainingSeconds <= 0);
                const canMarkComplete = !isCompleted && !isAccessRevoked && hasBeenOpened && timeExpired;

                return {
                    ...learningFile,
                    iconName: this.fileIconName(learningFile.mimeType, learningFile.name),
                    isCompleted,
                    hasBeenOpened,
                    isAccessRevoked,
                    remainingSeconds,
                    timeExpired,
                    canMarkComplete,
                    timerDisplay: this.formatTimer(remainingSeconds)
                };
            });
    }

    // ═══════════════════════════════════════════════════════════════
    // "Next Lesson" navigation — jump to the next folder ANYWHERE in
    // the tree that contains files, once every file in the current
    // folder is marked Completed. Mirrors the Apex traversal in
    // findNextContentFolderFirstFile: a full pre-order walk of the
    // whole folder tree (folder, then its subfolders in Sort_Order__c/
    // Name order, then next sibling), filtered down to folders that
    // actually contain files. The earlier version only checked
    // immediate siblings, which broke as soon as the next content
    // folder lived at a different depth (e.g. popping back up from a
    // nested folder to a sibling several levels higher).
    // ═══════════════════════════════════════════════════════════════

    // Flattens the folder tree into pre-order, pairing each folder with the
    // breadcrumb path (root → ... → that folder) needed to navigate to it directly.
    buildOrderedFolderList(folders, parentPath) {
        const sorted = this.sortBySortOrderThenName(folders);
        let result = [];
        for (const folder of sorted) {
            const path = [...parentPath, { id: folder.id, name: folder.name }];
            result.push({ folder, path });
            if (folder.subFolders && folder.subFolders.length) {
                result = result.concat(this.buildOrderedFolderList(folder.subFolders, path));
            }
        }
        return result;
    }

    get orderedContentFolderEntries() {
        const allOrdered = this.buildOrderedFolderList(this.rootFolders, []);
        return allOrdered.filter((entry) => entry.folder.files && entry.folder.files.length > 0);
    }

    get nextContentFolderEntry() {
        if (!this.currentFolder) return null;
        const list = this.orderedContentFolderEntries;
        const currentFolderIndex = list.findIndex((entry) => entry.folder.id === this.currentFolder.id);
        if (currentFolderIndex === -1 || currentFolderIndex + 1 >= list.length) return null;
        return list[currentFolderIndex + 1];
    }

    get allFilesCompletedInFolder() {
        const files = this.itemsToShow.files;
        return files.length > 0 && files.every((learningFile) => learningFile.completionStatus === 'Completed');
    }

    get showNextLessonButton() {
        // Also show if the server just reported unlocking the next folder
        // but the refreshed tree hasn't been observed yet.
        return this.allFilesCompletedInFolder && (this.nextContentFolderEntry != null || this._nextFolderUnlockedPending === true);
    }

    get showPathCompleteMessage() {
        return this.allFilesCompletedInFolder && this.nextContentFolderEntry == null && this.currentFolder != null && !this.showAccessGapMessage;
    }

    // Shared count derivation used by both showAccessGapMessage and accessGapMessage below.
    // Kept as one getter so the fallback logic only has to be correct (and updated) in one
    // place. Fallback logic is unchanged from the original: totalFilesCount/visibleFilesCount
    // fall back to 0 / itemsToShow.files.length respectively when null/undefined.
    // Note: when there's no currentFolder, callers already guard on that before reading these
    // values, so the {0, 0} returned here is never actually consumed.
    get _accessGapCounts() {
        if (!this.currentFolder) {
            return { totalCount: 0, visibleCount: 0 };
        }
        const totalCount = this.currentFolder.totalFilesCount != null ? this.currentFolder.totalFilesCount : 0;
        const visibleCount = this.currentFolder.visibleFilesCount != null ? this.currentFolder.visibleFilesCount : this.itemsToShow.files.length;
        return { totalCount, visibleCount };
    }

    get showAccessGapMessage() {
        if (!this.currentFolder) {
            return false;
        }

        const { totalCount, visibleCount } = this._accessGapCounts;
        return this.allFilesCompletedInFolder && this.nextContentFolderEntry == null && totalCount > visibleCount;
    }

    get showAccessRequestActions() {
        return this.allFilesCompletedInFolder &&
            this.isNextContentRequestAvailable &&
            !this.showNextLessonButton;
    }

    get accessGapMessage() {
        if (!this.currentFolder || !this.showAccessGapMessage) {
            return '';
        }

        return 'Next file and folder are locked. Please contact your Admin/Mentor for access.';
    }

    get hasRequestedCurrentFolderAccess() {
        return this.accessRequestSent && this.accessRequestFolderId === this.currentFolder?.id;
    }

    get isAccessRequestDisabled() {
        return this.isCheckingAccessRequest || this.isAccessRequestSubmitting ||
            (this.hasRequestedCurrentFolderAccess &&
                (!this.accessRequestCanNotifyAgain || this.accessRequestNotificationSent));
    }

    get accessRequestButtonLabel() {
        if (this.isCheckingAccessRequest) return 'Checking request...';
        if (this.isAccessRequestSubmitting) return 'Sending request...';
        if (!this.hasRequestedCurrentFolderAccess) return 'Request access from Mentor';
        if (!this.accessRequestCanNotifyAgain) {
            return this.accessRequestStatus === 'Working' ? 'Request in progress' : 'Request completed';
        }
        if (this.accessRequestNotificationSent) {
            return this.accessRequestWasCreated ? 'Request sent' : 'Reminder sent';
        }
        return 'Notify mentor again';
    }

    get accessRequestCaption() {
        if (this.accessRequestStatus === 'Working') {
            return 'Your mentor is reviewing this request.';
        }
        if (this.accessRequestStatus === 'Closed') {
            return 'This request is completed. Contact your mentor if you still need access.';
        }
        return 'An open request already exists. You can notify your mentor again if needed.';
    }

    loadAccessRequestStatus() {
        const folderId = this.currentFolder?.id;
        this.accessRequestFolderId = folderId;
        this.accessRequestSent = false;
        this.accessRequestNotificationSent = false;
        this.accessRequestWasCreated = false;
        this.accessRequestStatus = undefined;
        this.accessRequestCanNotifyAgain = false;
        if (!folderId) {
            this.isCheckingAccessRequest = false;
            return;
        }

        this.isCheckingAccessRequest = true;
        this.isNextContentRequestAvailable = false;
        getNextContentAccessRequestStatus({ currentFolderId: folderId })
            .then((requestStatus) => {
                if (this.currentFolder?.id === folderId) {
                    this.isNextContentRequestAvailable = requestStatus.available === true;
                    this.accessRequestSent = requestStatus.alreadyRequested === true;
                    this.accessRequestStatus = requestStatus.requestStatus;
                    this.accessRequestCanNotifyAgain = requestStatus.canNotifyAgain === true;
                }
            })
            .catch((error) => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Error',
                    message: error.body?.message || 'The access request status could not be checked.',
                    variant: 'error'
                }));
            })
            .finally(() => {
                if (this.currentFolder?.id === folderId) {
                    this.isCheckingAccessRequest = false;
                }
            });
    }

    async handleRequestNextContentAccess() {
        if (!this.currentFolder || this.isAccessRequestDisabled) {
            return;
        }

        this.isAccessRequestSubmitting = true;
        try {
            const result = await requestNextContentAccess({
                currentFolderId: this.currentFolder.id
            });
            this.accessRequestSent = true;
            this.accessRequestFolderId = this.currentFolder.id;
            this.accessRequestStatus = result.requestStatus;
            this.accessRequestCanNotifyAgain = result.canNotifyAgain === true;
            this.accessRequestNotificationSent = true;
            this.accessRequestWasCreated = !result.alreadyRequested;
            this.dispatchEvent(new ShowToastEvent({
                title: result.alreadyRequested ? 'Mentor Notified' : 'Request Sent',
                message: result.message,
                variant: 'success'
            }));
        } catch (error) {
            const message = error?.body?.message || error?.message || 'Unable to send your access request.';
            this.dispatchEvent(new ShowToastEvent({
                title: 'Request Failed',
                message,
                variant: 'error',
                mode: 'sticky'
            }));
        } finally {
            this.isAccessRequestSubmitting = false;
        }
    }

    handleNextLessonClick() {
        const entry = this.nextContentFolderEntry;
        if (!entry) return;
        // Use the full breadcrumb path to the target folder — it may sit at a
        // completely different depth than the current folder, so we can't just
        // swap the last breadcrumb like a same-level sibling jump would.
        this.breadcrumbs = entry.path;
        this.currentFolder = entry.folder;
        this.loadAccessRequestStatus();
    }

    // ═══════════════════════════════════════════════════════════════

    formatTimer(seconds) {
        if (seconds <= 0) return 'Ready';
        const mins = Math.floor(seconds / 60);
        const secs = seconds % 60;
        return `${mins}:${secs.toString().padStart(2, '0')}`;
    }

    fileIconName(mimeType, fileName) {
        const type = (mimeType || '').toLowerCase();
        if (type.includes('pdf')) return 'doctype:pdf';
        if (type.includes('video')) return 'doctype:video';
        if (type.includes('image')) return 'doctype:image';
        if (type.includes('word') || type.includes('officedocument.wordprocessing')) return 'doctype:word';
        if (type.includes('powerpoint') || type.includes('presentation')) return 'doctype:ppt';
        if (type.includes('excel') || type.includes('sheet')) return 'doctype:excel';

        const name = (fileName || '').toLowerCase();
        if (name.endsWith('.pdf')) return 'doctype:pdf';
        if (name.endsWith('.doc') || name.endsWith('.docx')) return 'doctype:word';
        if (name.endsWith('.ppt') || name.endsWith('.pptx')) return 'doctype:ppt';
        if (name.endsWith('.xls') || name.endsWith('.xlsx') || name.endsWith('.csv')) return 'doctype:excel';
        if (name.endsWith('.mp4') || name.endsWith('.mov') || name.endsWith('.avi')) return 'doctype:video';
        if (name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.png') || name.endsWith('.gif')) return 'doctype:image';
        return 'doctype:unknown';
    }

    restoreNavigationState() {
        const params = new URLSearchParams(window.location.search);
        const folderId = params.get('folderId');
        if (!folderId) {
            this.breadcrumbs = [];
            this.currentFolder = undefined;
            return;
        }

        const existingBreadcrumbs = params.get('breadcrumbs');
        if (existingBreadcrumbs) {
            try {
                this.breadcrumbs = JSON.parse(existingBreadcrumbs);
            } catch {
                try {
                    this.breadcrumbs = JSON.parse(decodeURIComponent(existingBreadcrumbs));
                } catch {
                    this.breadcrumbs = [];
                }
            }
        } else {
            this.breadcrumbs = [];
        }

        this.currentFolder = undefined;
    }

    persistNavigationState() {
        const params = new URLSearchParams(window.location.search);
        if (this.breadcrumbs.length > 0 && this.currentFolder) {
            params.set('folderId', this.currentFolder.id);
            params.set('breadcrumbs', JSON.stringify(this.breadcrumbs));
        } else {
            params.delete('folderId');
            params.delete('breadcrumbs');
        }

        const query = params.toString();
        const newUrl = `${window.location.pathname}${query ? `?${query}` : ''}${window.location.hash}`;
        window.history.replaceState(window.history.state, '', newUrl);
    }

    handleFolderClick(event) {
        const folderId = event.currentTarget.dataset.id;
        const folder = this.findFolderById(this.rootFolders, folderId);

        if (folder) {
            this.breadcrumbs = [...this.breadcrumbs, { id: folder.id, name: folder.name }];
            this.currentFolder = folder;
            this.persistNavigationState();
            this.loadAccessRequestStatus();
        }
    }

    handleBreadcrumbClick(event) {
        const targetId = event.currentTarget.dataset.id;

        if (targetId === 'root') {
            this.breadcrumbs = [];
            this.currentFolder = undefined;
            this.persistNavigationState();
            this.loadAccessRequestStatus();
            return;
        }

        const targetBreadcrumbIndex = this.breadcrumbs.findIndex(
            (breadcrumb) => breadcrumb.id === targetId
        );
        this.breadcrumbs = this.breadcrumbs.slice(0, targetBreadcrumbIndex + 1);
        this.currentFolder = this.findFolderById(this.rootFolders, targetId);
        this.persistNavigationState();
        this.loadAccessRequestStatus();
    }

    handleBackClick() {
        if (this.breadcrumbs.length <= 1) {
            this.breadcrumbs = [];
            this.currentFolder = undefined;
            this.persistNavigationState();
            this.loadAccessRequestStatus();
            return;
        }
        const newCrumbs = this.breadcrumbs.slice(0, -1);
        const targetId = newCrumbs[newCrumbs.length - 1].id;
        this.breadcrumbs = newCrumbs;
        this.currentFolder = this.findFolderById(this.rootFolders, targetId);
        this.persistNavigationState();
        this.loadAccessRequestStatus();
    }

    findFolderById(folders, targetFolderId) {
        for (const folder of folders) {
            if (folder.id === targetFolderId) return folder;
            if (folder.subFolders && folder.subFolders.length) {
                const found = this.findFolderById(folder.subFolders, targetFolderId);
                if (found) return found;
            }
        }
        return null;
    }

    handleFileClick(event) {
        event.stopPropagation();
        const url = event.currentTarget.dataset.url;
        const fileId = event.currentTarget.dataset.fileId;
        const file = this.displayFiles.find((learningFile) => learningFile.id === fileId);

        if (!file) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error',
                message: 'This learning file could not be found. Refresh the page and try again.',
                variant: 'error'
            }));
            return;
        }

        if (file.isAccessRevoked) {
            this.error = `"${file.name}" access has been revoked. Please contact your administrator.`;
            return;
        }

        if (!file.hasBeenOpened) {
            recordFileOpened({ fileId: file.id })
                .then(() => {
                    this.loadTree();
                })
                .catch((error) => {
                    this.dispatchEvent(new ShowToastEvent({
                        title: 'Error',
                        message: error.body?.message || 'The learning file view could not be recorded.',
                        variant: 'error'
                    }));
                });
        }

        if (url) {
            window.open(url, '_blank', 'noopener,noreferrer');
        } else {
            this.error = `"${file.name}" doesn't have a link configured yet. Please contact your administrator.`;
        }
    }

    handleCompleteFile(event) {
        event.stopPropagation();

        const fileId = event.currentTarget.dataset.fileId;
        const file = this.displayFiles.find((learningFile) => learningFile.id === fileId);

        if (!file) {
            return;
        }

        if (!file.canMarkComplete) {
            return;
        }

        this.isLoading = true;

        markFileComplete({ fileId: file.id })
            .then((result) => {
                // If the server created access for the first file of the next
                // folder, set a transient flag so the Next Lesson button can
                // be shown immediately while we reload the tree.
                this._nextFolderUnlockedPending = !!result.nextFolderUnlocked;

                // Wait for the refreshed tree so computed getters reflect the
                // updated completion/access state before we clear loading.
                return this.loadTree().then(() => {
                    // Clear the transient flag if the refreshed tree already
                    // exposes the next content folder entry.
                    if (this.nextContentFolderEntry) {
                        this._nextFolderUnlockedPending = false;
                    }
                });
            })
            .catch((error) => {
                this.error = error.body ? error.body.message : error.message;
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleFeedbackIconClick(event) {
        event.stopPropagation();
        const fileId = event.currentTarget.dataset.fileId;
        const file = this.displayFiles.find((learningFile) => learningFile.id === fileId);
        this.feedbackFileId = fileId;
        this.feedbackFileName = file ? file.name : '';
        this.feedbackComment = '';
        this.feedbackModalError = undefined;
        this.showFeedbackModal = true;
    }

    handleFeedbackCommentChange(event) {
        this.feedbackComment = event.target.value;
    }

    handleFeedbackCancel() {
        this.showFeedbackModal = false;
        this.feedbackFileId = undefined;
        this.feedbackComment = '';
    }

    stopPropagation(event) {
        event.stopPropagation();
    }

    handleFeedbackSubmit() {
        if (!this.feedbackComment || !this.feedbackComment.trim()) {
            this.feedbackModalError = 'Please enter a comment.';
            return;
        }

        this.isFeedbackSubmitting = true;
        submitFileFeedback({ fileId: this.feedbackFileId, commentText: this.feedbackComment })
            .then(() => {
                this.showFeedbackModal = false;
                this.feedbackFileId = undefined;
                this.feedbackComment = '';
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Feedback submitted',
                        message: 'Thanks — your feedback has been submitted.',
                        variant: 'success'
                    })
                );
            })
            .catch((error) => {
                this.feedbackModalError = error.body ? error.body.message : error.message;
            })
            .finally(() => {
                this.isFeedbackSubmitting = false;
            });
    }
}