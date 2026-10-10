import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getTodayRecord from '@salesforce/apex/AttendanceController.getTodayRecord';
import submitPunch from '@salesforce/apex/AttendanceController.submitPunch';
import submitAppeal from '@salesforce/apex/AttendanceController.submitAppeal';
import getHistory from '@salesforce/apex/AttendanceController.getHistory';

// Lunch Check-In = lunch starts ("Lunch In"), Lunch Check-Out = lunch ends ("Lunch Out")
const TYPE_LABELS = {
    'Office Check-In': 'Office Check-In',
    'Lunch Check-In': 'Lunch In',
    'Lunch Check-Out': 'Lunch Out',
    'Office Check-Out': 'Office Check-Out'
};

const TYPE_ICONS = {
    'Office Check-In': 'utility:check',
    'Lunch Check-In': 'utility:food_and_drink',
    'Lunch Check-Out': 'utility:logout',
    'Office Check-Out': 'utility:logout'
};

const LOCATION_SAMPLE_DURATION_MS = 5000;
const TARGET_LOCATION_ACCURACY_METERS = 10;

function formatIsoDate(dateValue) {
    return dateValue.toISOString().slice(0, 10);
}

export default class AttendanceCapture extends LightningElement {
    // ---- Today / capture / appeal state ----
    isCapturing = false;
    isGettingLocation = false;
    errorMessage = '';
    resultMessage = '';

    appealOpenForId = null;
    appealText = '';
    isSubmittingAppeal = false;

    wiredRecordResult;
    lunchCountdownIntervalId;
    officeCheckInOpeningTimestamp = NaN;
    lastOfficeOpeningRefreshAt;
    clockNow = Date.now();
    capturedCoords = null;
    selectedPunchType = null;

    // ---- History state ----
    showHistory = false;
    historyLoaded = false;
    historyStartDate;
    historyEndDate;
    historyLateOnly = false;
    isHistoryLoading = false;
    historyErrorMessage = '';
    historyRows = [];
    historyPageNumber = 0;
    historyTotalCount = 0;

    // KPI Summary Metrics for History
    totalLateCount = 0;
    officeLateCount = 0;
    lunchLateCount = 0;
    totalDeductionAmount = 0;

    showCameraModal = false;
    isPhotoConfirmStep = false;
    capturedPhotoDataUrl = null;
    capturedPhotoBase64 = null;
    cameraErrorMessage = '';
    cameraStream = null;

    @wire(getTodayRecord)
    wiredRecord(result) {
        this.wiredRecordResult = result;
        if (result.data) {
            this.clockNow = Date.now();
            this.syncLunchCountdown(result.data);
        } else if (result.error) {
            this.stopLunchCountdown();
        }
    }

    disconnectedCallback() {
        this.stopLunchCountdown();
        if (this.cameraStream) {
            this.cameraStream.getTracks().forEach((track) => track.stop());
            this.cameraStream = null;
        }
    }

    syncLunchCountdown(record) {
        const lunchStarted = record.entries?.some(
            (entry) => entry.type === 'Lunch Check-In' && entry.completed
        );
        const lunchEnded = record.entries?.some(
            (entry) => entry.type === 'Lunch Check-Out' && entry.completed
        );
        const officeEnded = record.entries?.some(
            (entry) => entry.type === 'Office Check-Out' && entry.completed
        );
        const hasDuration = Number(record.lunchDurationMinutes) > 0;
        const nextOfficeCheckInOpensAt = record.nextOfficeCheckInOpensAt
            ? new Date(record.nextOfficeCheckInOpensAt).getTime()
            : NaN;
        this.officeCheckInOpeningTimestamp = nextOfficeCheckInOpensAt;
        const officeCheckInWaiting = Number.isFinite(nextOfficeCheckInOpensAt) &&
            nextOfficeCheckInOpensAt > this.clockNow;
        const lunchCountdownRunning = lunchStarted && !lunchEnded && !officeEnded &&
            hasDuration && this.lunchCountdownSeconds > 0;

        if (lunchCountdownRunning || officeCheckInWaiting) {
            if (!this.lunchCountdownIntervalId) {
                this.lunchCountdownIntervalId = setInterval(() => {
                    this.clockNow = Date.now();
                    this.syncLunchCountdown(this.record);
                    const currentOpeningTimestamp = this.officeCheckInOpeningTimestamp;
                    if (Number.isFinite(currentOpeningTimestamp) &&
                        this.clockNow >= currentOpeningTimestamp &&
                        this.lastOfficeOpeningRefreshAt !== currentOpeningTimestamp) {
                        this.lastOfficeOpeningRefreshAt = currentOpeningTimestamp;
                        refreshApex(this.wiredRecordResult).catch((error) => {
                            this.errorMessage = error?.body?.message ||
                                error?.message ||
                                'Could not refresh attendance at the next check-in opening time.';
                        });
                    }
                }, 1000);
            }
        } else {
            this.stopLunchCountdown();
        }
    }

    stopLunchCountdown() {
        if (this.lunchCountdownIntervalId) {
            clearInterval(this.lunchCountdownIntervalId);
            this.lunchCountdownIntervalId = null;
        }
    }

    get isLoading() {
        return !this.wiredRecordResult || (!this.wiredRecordResult.data && !this.wiredRecordResult.error);
    }

    get record() {
        return this.wiredRecordResult && this.wiredRecordResult.data
            ? this.wiredRecordResult.data
            : null;
    }

    get isDone() {
        return this.record ? this.record.isDone : false;
    }

    get displayEntries() {
        if (!this.record) {
            return [];
        }
        const lunchEnded = this.record.entries.some(
            (entry) => entry.type === 'Lunch Check-Out' && entry.completed
        );
        return this.record.entries.map((entry) => {
            const isAppealOpen = this.appealOpenForId === entry.id;
            const canAppeal = entry.completed && entry.status === 'Not Excused' && !entry.excusalReason;
            const appealSubmitted = entry.completed && entry.status === 'Pending' && !!entry.excusalReason;
            const officeCheckInOpensAt = entry.officeCheckInOpensAt
                ? new Date(entry.officeCheckInOpensAt).getTime()
                : NaN;
            const officeCheckInWaiting = entry.type === 'Office Check-In' &&
                !entry.completed &&
                Number.isFinite(officeCheckInOpensAt) && officeCheckInOpensAt > this.clockNow;

            return {
                ...entry,
                key: entry.type,
                label: TYPE_LABELS[entry.type],
                iconName: TYPE_ICONS[entry.type],
                formattedTime: entry.completed ? this.formatTime(entry.eventTimestamp) : '—',
                showLunchCountdown: entry.type === 'Lunch Check-In' &&
                    entry.completed &&
                    !lunchEnded &&
                    this.hasActiveLunchCountdown &&
                    this.lunchCountdownSeconds > 0,
                lunchCountdownText: entry.type === 'Lunch Check-In'
                    ? this.lunchCountdownText(entry.eventTimestamp)
                    : '',
                badgeText: officeCheckInWaiting
                    ? `Opens at ${this.formatTime(entry.officeCheckInOpensAt)}`
                    : this.badgeTextFor(entry, appealSubmitted),
                badgeClass: this.badgeClassFor(entry, appealSubmitted),
                rowClass: entry.completed ? 'punch-row punch-row_done' : 'punch-row punch-row_pending',
                canAppeal,
                appealSubmitted,
                isAppealOpen,
                disableButton: entry.completed || !entry.eligible || officeCheckInWaiting || this.isCapturing
            };
        });
    }

    get hasActiveLunchCountdown() {
        return this.lunchCountdownIntervalId !== null && this.lunchCountdownIntervalId !== undefined;
    }

    get lunchCountdownSeconds() {
        const lunchStart = this.record?.entries?.find(
            (entry) => entry.type === 'Lunch Check-In' && entry.completed
        );
        const lunchDurationMinutes = Number(this.record?.lunchDurationMinutes);
        const startTimestamp = lunchStart?.eventTimestamp ? new Date(lunchStart.eventTimestamp).getTime() : NaN;
        if (!Number.isFinite(startTimestamp) || !Number.isFinite(lunchDurationMinutes)) {
            return 0;
        }

        const deadline = startTimestamp + lunchDurationMinutes * 60 * 1000;
        return Math.max(0, Math.ceil((deadline - this.clockNow) / 1000));
    }

    lunchCountdownText(eventTimestamp) {
        const startTimestamp = eventTimestamp ? new Date(eventTimestamp).getTime() : NaN;
        const lunchDurationMinutes = Number(this.record?.lunchDurationMinutes);
        if (!Number.isFinite(startTimestamp) || !Number.isFinite(lunchDurationMinutes)) {
            return '';
        }

        const deadline = startTimestamp + lunchDurationMinutes * 60 * 1000;
        const secondsRemaining = Math.max(0, Math.ceil((deadline - this.clockNow) / 1000));
        const minutes = String(Math.floor(secondsRemaining / 60)).padStart(2, '0');
        const seconds = String(secondsRemaining % 60).padStart(2, '0');
        return `${minutes}:${seconds}`;
    }

    get todayRecordErrorMessage() {
        const err = this.wiredRecordResult && this.wiredRecordResult.error;
        return err ? (err?.body?.message ?? err?.message ?? 'Could not load today\'s attendance.') : '';
    }

    async openCameraModal() {
        this.cameraErrorMessage = '';
        this.capturedPhotoDataUrl = null;
        this.capturedPhotoBase64 = null;
        this.isPhotoConfirmStep = false;
        this.isCapturing = false;
        this.showCameraModal = true;

        try {
            this.cameraStream = await navigator.mediaDevices.getUserMedia({
                video: { facingMode: 'user' },
                audio: false
            });
            Promise.resolve().then(() => {
                const video = this.template.querySelector('.camera-video');
                if (video) {
                    video.srcObject = this.cameraStream;
                }
            });
        } catch (error) {
            this.cameraErrorMessage = this.cameraErrorMessageFor(error);
            this.isCapturing = false;
        }
    }

    cameraErrorMessageFor(error) {
        if (error && error.name === 'NotAllowedError') {
            return 'Camera access is turned off for this site. Enable it in your browser\'s site settings, then try again.';
        }
        if (error && error.name === 'NotFoundError') {
            return 'No camera was found on this device.';
        }
        return 'Couldn\'t start the camera. Please try again.';
    }

    handleCaptureFrame() {
        const video = this.template.querySelector('.camera-video');
        if (!video || !video.videoWidth) {
            this.cameraErrorMessage = 'Camera isn\'t ready yet. Please wait a moment and try again.';
            return;
        }
        const canvas = document.createElement('canvas');
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(video, 0, 0, canvas.width, canvas.height);

        const dataUrl = canvas.toDataURL('image/jpeg', 0.8);
        this.capturedPhotoDataUrl = dataUrl;
        this.capturedPhotoBase64 = dataUrl.split(',')[1];
        this.isPhotoConfirmStep = true;
    }

    handleRetake() {
        this.capturedPhotoDataUrl = null;
        this.capturedPhotoBase64 = null;
        this.isPhotoConfirmStep = false;
        Promise.resolve().then(() => {
            const video = this.template.querySelector('.camera-video');
            if (video && this.cameraStream) {
                video.srcObject = this.cameraStream;
            }
        });
    }

    async handleConfirmPhoto() {
        try {
            this.isCapturing = true;
            const compressedBase64 = await this.compressImage(this.capturedPhotoBase64);
            this.closeCameraModal();
            this.doSubmit(compressedBase64, 'image/jpeg');
        } catch (error) {
            this.cameraErrorMessage = 'Failed to process photo. Please try again.';
        } finally {
            this.isCapturing = false;
        }
    }

    handleCancelCamera() {
        this.closeCameraModal();
        this.isCapturing = false;
        this.selectedPunchType = null;
    }

    closeCameraModal() {
        if (this.cameraStream) {
            this.cameraStream.getTracks().forEach((track) => track.stop());
            this.cameraStream = null;
        }
        this.showCameraModal = false;
        this.isPhotoConfirmStep = false;
        this.capturedPhotoDataUrl = null;
        this.capturedPhotoBase64 = null;
        this.cameraErrorMessage = '';
    }

    handleHistoryPrevPage() {
        if (this.historyPageNumber > 0) {
            this.historyPageNumber -= 1;
            this.loadHistory();
        }
    }

    handleHistoryNextPage() {
        if (this.hasMoreHistoryPages) {
            this.historyPageNumber += 1;
            this.loadHistory();
        }
    }

    get historyTotalPages() {
        return Math.max(1, Math.ceil(this.historyTotalCount / 10));
    }

    get historyPageLabel() {
        return `Page ${this.historyPageNumber + 1} of ${this.historyTotalPages}`;
    }

    get isFirstHistoryPage() {
        return this.historyPageNumber === 0;
    }

    get hasMoreHistoryPages() {
        return (this.historyPageNumber + 1) * 10 < this.historyTotalCount;
    }

    get noMoreHistoryPages() { return !this.hasMoreHistoryPages; }

    showPunchModal = false;

    get nextPunchEntry() {
        return this.displayEntries.find((entry) => !entry.disableButton)
            || this.displayEntries.find((entry) => !entry.completed);
    }

    get nextPunchLabel() {
        if (this.isNextPunchDisabled) {
            return `Office Check-In opens at ${this.formatTime(this.nextPunchEntry.officeCheckInOpensAt)}`;
        }
        return this.nextPunchEntry ? this.nextPunchEntry.label : 'Log Attendance';
    }

    get isMainPunchDisabled() {
        return this.isCapturing || this.isNextPunchDisabled;
    }

    get isNextPunchDisabled() {
        return this.nextPunchEntry?.type === 'Office Check-In' &&
            !!this.nextPunchEntry.officeCheckInOpensAt &&
            new Date(this.nextPunchEntry.officeCheckInOpensAt).getTime() > this.clockNow;
    }

    openPunchModal() {
        this.showPunchModal = true;
    }

    closePunchModal() {
        this.showPunchModal = false;
    }

    stopPropagation(event) {
        event.stopPropagation();
    }

    handleCaptureFromModal(event) {
        this.closePunchModal();
        this.handleCapture(event);
    }

    formatTime(isoString) {
        if (!isoString) return '—';
        const eventDate = new Date(isoString);
        return eventDate.toLocaleTimeString('en-IN', {
            timeZone: 'Asia/Kolkata',
            hour: '2-digit',
            minute: '2-digit',
            hour12: true
        });
    }

    formatLateMinutes(minutes) {
        if (!minutes || minutes <= 0) return '0 min';
        if (minutes < 60) return `${minutes} min`;
        const hours = Math.floor(minutes / 60);
        const mins = minutes % 60;
        return mins > 0 ? `${hours}h ${mins}m` : `${hours}h`;
    }

    badgeTextFor(entry, appealSubmitted) {
        if (!entry.completed) return 'Not yet';
        if (entry.status === 'On Time') return 'On time';
        if (entry.status === 'Excused') return 'Excused';
        if (entry.status === 'Not Excused' && !appealSubmitted) return `Late ${this.formatLateMinutes(entry.lateMinutes)}`;
        if (entry.status === 'Not Excused') return 'Deduction applied';
        if (entry.status === 'Pending' && appealSubmitted) return 'Appeal submitted';
        if (entry.status === 'Pending') return `Late ${this.formatLateMinutes(entry.lateMinutes)}`;
        if (!entry.status) return 'Recorded';
        return entry.status;
    }

    badgeClassFor(entry, appealSubmitted) {
        if (!entry.completed) return 'badge badge_muted';
        if (entry.status === 'On Time' || entry.status === 'Excused') return 'badge badge_success';
        if (entry.status === 'Not Excused') return 'badge badge_danger';
        if (entry.status === 'Pending' && appealSubmitted) return 'badge badge_info';
        if (entry.status === 'Pending') return 'badge badge_warning';
        return 'badge badge_muted';
    }

    async handleCapture(event) {
        this.errorMessage = '';
        this.resultMessage = '';
        this.selectedPunchType = event.currentTarget.dataset.type;
        this.isCapturing = true;
        this.isGettingLocation = true;

        if (!navigator.geolocation || !navigator.geolocation.watchPosition) {
            this.errorMessage = 'Location isn\'t supported on this device/browser.';
            this.isCapturing = false;
            this.isGettingLocation = false;
            return;
        }

        try {
            this.capturedCoords = await this.getBestLocation();
            this.isGettingLocation = false;

            const entry = this.record
                ? this.record.entries.find((recordEntry) => recordEntry.type === this.selectedPunchType)
                : null;

            // No photo required for this punch (e.g. Office Check-Out): submit directly
            if (entry && entry.needsPhoto === false) {
                this.doSubmit(null, null);
                return;
            }

            this.openCameraModal();
        } catch (error) {
            this.errorMessage = this.locationErrorMessage(error);
            this.isCapturing = false;
            this.isGettingLocation = false;
        }
    }

    getBestLocation() {
        return new Promise((resolve, reject) => {
            let bestPosition;
            let lastLocationError;
            let watchId;
            let sampleTimerId;
            let isFinished = false;

            const finishSampling = (error) => {
                if (isFinished) {
                    return;
                }
                isFinished = true;
                window.clearTimeout(sampleTimerId);
                if (watchId !== undefined) {
                    navigator.geolocation.clearWatch(watchId);
                }
                if (bestPosition) {
                    resolve(bestPosition.coords);
                } else {
                    reject(error || lastLocationError || {
                        code: 3,
                        message: 'No GPS reading was available. Please try again.'
                    });
                }
            };

            // Bound the GPS sampling period so a location watch cannot remain open indefinitely.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            sampleTimerId = window.setTimeout(
                () => finishSampling(lastLocationError),
                LOCATION_SAMPLE_DURATION_MS
            );

            watchId = navigator.geolocation.watchPosition(
                (position) => {
                    const accuracy = position.coords.accuracy;
                    if (Number.isFinite(accuracy) &&
                        (!bestPosition || accuracy < bestPosition.coords.accuracy)) {
                        bestPosition = position;
                    }
                    if (bestPosition && bestPosition.coords.accuracy <= TARGET_LOCATION_ACCURACY_METERS) {
                        finishSampling();
                    }
                },
                (error) => {
                    lastLocationError = error;
                    finishSampling(error);
                },
                { enableHighAccuracy: true, timeout: 20000, maximumAge: 0 }
            );
        });
    }

    locationErrorMessage(error) {
        switch (error.code) {
            case 1:
                return 'Location access is turned off for this site. Enable it in your browser\'s site settings, then try again.';
            case 2:
                return 'Couldn\'t determine your location. Move to an area with better signal and try again.';
            case 3:
                return 'Location took too long to respond. Please try again.';
            default:
                return 'Location error: ' + error.message;
        }
    }

    async compressImage(base64Data, maxWidth = 480, quality = 0.6) {
        return new Promise((resolve) => {
            const img = new Image();
            img.onload = () => {
                const canvas = document.createElement('canvas');
                const scale = Math.min(1, maxWidth / img.width);
                canvas.width = img.width * scale;
                canvas.height = img.height * scale;
                const ctx = canvas.getContext('2d');
                ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
                const compressed = canvas.toDataURL('image/jpeg', quality);
                resolve(compressed.split(',')[1]);
            };
            img.src = 'data:image/jpeg;base64,' + base64Data;
        });
    }

    async doSubmit(base64Photo, contentType) {
        try {
            const result = await submitPunch({
                punchType: this.selectedPunchType,
                latitude: this.capturedCoords.latitude,
                longitude: this.capturedCoords.longitude,
                accuracyMeters: this.capturedCoords.accuracy,
                photoBase64: base64Photo,
                contentType
            });
            if (result.success) {
                this.resultMessage = result.message;
            } else {
                this.errorMessage = result.message;
            }
            await refreshApex(this.wiredRecordResult);
            if (this.historyLoaded) {
                this.loadHistory();
            }
        } catch (error) {
            this.errorMessage = error?.body?.message ?? error?.message ?? 'An unexpected error occurred.';
        } finally {
            this.isCapturing = false;
            this.selectedPunchType = null;
        }
    }

    handleOpenAppeal(event) {
        this.errorMessage = '';
        this.appealOpenForId = event.currentTarget.dataset.id;
        this.appealText = '';
    }

    handleCancelAppeal() {
        this.appealOpenForId = null;
        this.appealText = '';
    }

    handleAppealTextChange(event) {
        this.appealText = event.target.value;
    }

    async handleSubmitAppeal(event) {
        const logId = event.currentTarget.dataset.id;
        if (!this.appealText || !this.appealText.trim()) {
            this.errorMessage = 'Please enter a reason before submitting.';
            return;
        }
        this.isSubmittingAppeal = true;
        try {
            await submitAppeal({ logId, reason: this.appealText.trim() });
            this.resultMessage = 'Appeal submitted for manager review.';
            this.appealOpenForId = null;
            this.appealText = '';
            await refreshApex(this.wiredRecordResult);
            if (this.historyLoaded) {
                this.loadHistory();
            }
        } catch (error) {
            this.historyErrorMessage = error?.body?.message ?? error?.message ?? 'An unexpected error occurred.';
        } finally {
            this.isSubmittingAppeal = false;
        }
    }

    handleToggleHistory() {
        this.showHistory = !this.showHistory;
        if (this.showHistory && !this.historyLoaded) {
            const today = new Date();
            const past = new Date();
            past.setDate(past.getDate() - 7);
            this.historyEndDate = formatIsoDate(today);
            this.historyStartDate = formatIsoDate(past);
            this.loadHistory();
        }
    }

    handleHistoryStartDateChange(event) {
        this.historyStartDate = event.target.value || null;
    }

    handleHistoryEndDateChange(event) {
        this.historyEndDate = event.target.value || null;
    }

    handleHistoryLateOnlyChange(event) {
        this.historyLateOnly = event.target.checked;
    }

    handleApplyHistoryFilter() {
        if (!this.historyStartDate || !this.historyEndDate) {
            this.historyErrorMessage = 'Please select both From and To dates before applying the filter.';
            return;
        }
        this.historyPageNumber = 0;
        this.loadHistory();
    }

    // Export history records to CSV spreadsheet file
    handleExport() {
        if (!this.historyRows || this.historyRows.length === 0) {
            this.historyErrorMessage = 'No history records available to export.';
            return;
        }

        const headers = ['Date', 'Office In', 'Office Out', 'Lunch In', 'Lunch Out', 'Office Late', 'Lunch Late', 'Deduction', 'Status'];
        const csvRows = [headers.join(',')];

        this.historyRows.forEach(row => {
            const values = [
                `"${row.date || ''}"`,
                `"${row.officeIn || ''}"`,
                `"${row.officeOut || ''}"`,
                `"${row.lunchIn || ''}"`,
                `"${row.lunchOut || ''}"`,
                `"${row.officeLateMinutes || ''}"`,
                `"${row.lunchLateMinutes || ''}"`,
                `"${row.deduction || 0}"`,
                `"${row.statusText || ''}"`
            ];
            csvRows.push(values.join(','));
        });

        const csvContent = 'data:text/csv;charset=utf-8,' + csvRows.join('\n');
        const encodedUri = encodeURI(csvContent);
        const link = document.createElement('a');
        link.setAttribute('href', encodedUri);
        link.setAttribute('download', `My_Attendance_History.csv`);
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
    }

    async loadHistory() {
        if (!this.historyStartDate || !this.historyEndDate) {
            this.historyErrorMessage = 'Please select both From and To dates before applying the filter.';
            this.historyLoaded = false;
            this.historyRows = [];
            return;
        }

        this.isHistoryLoading = true;
        this.historyErrorMessage = '';
        try {
            const result = await getHistory({
                startDate: this.historyStartDate,
                endDate: this.historyEndDate,
                lateOnly: this.historyLateOnly,
                pageNumber: this.historyPageNumber
            });
            this.historyRows = result.records.map((attendanceRecord) => this.mapHistoryRow(attendanceRecord));
            this.historyTotalCount = result.totalCount;

            this.officeLateCount = result.records.filter(
                row => Number(row.Office_Late_Minutes__c || 0) > 0
            ).length;
            this.lunchLateCount = result.records.filter(
                row => Number(row.Lunch_Late_Minutes__c || 0) > 0
            ).length;
            this.totalLateCount = this.officeLateCount + this.lunchLateCount;

            this.totalDeductionAmount = result.records.reduce((sum, row) => sum + (row.Total_Deduction_Amount__c || 0), 0);

            this.historyLoaded = true;
        } catch (error) {
            this.historyErrorMessage = error?.body?.message ?? error?.message ?? 'An unexpected error occurred.';
        } finally {
            this.isHistoryLoading = false;
        }
    }

    mapHistoryRow(attendanceRecord) {
        const deduction = attendanceRecord.Total_Deduction_Amount__c || 0;
        const statuses = attendanceRecord.Attendance_Logs__r
            ? attendanceRecord.Attendance_Logs__r.map((attendanceLog) => attendanceLog.Status__c).filter(Boolean)
            : [];

        let statusText = 'On time';
        let statusClass = 'badge badge_success';
        if (statuses.includes('Not Excused')) {
            statusText = 'Deduction applied';
            statusClass = 'badge badge_danger';
        } else if (statuses.includes('Excused')) {
            statusText = 'Excused';
            statusClass = 'badge badge_success';
        } else if (statuses.includes('Pending')) {
            statusText = 'Late — pending review';
            statusClass = 'badge badge_warning';
        }
        return {
            id: attendanceRecord.Id,
            date: this.formatDate(attendanceRecord.Date__c),
            officeIn: this.formatTime(attendanceRecord.Office_Check_In_Time__c),
            officeOut: this.formatTime(attendanceRecord.Office_Check_Out_Time__c),
            lunchIn: this.formatTime(attendanceRecord.Lunch_In_Time__c),
            lunchOut: this.formatTime(attendanceRecord.Lunch_Out_Time__c),
            officeLateMinutes: this.formatLateMinutes(attendanceRecord.Office_Late_Minutes__c || 0),
            lunchLateMinutes: this.formatLateMinutes(attendanceRecord.Lunch_Late_Minutes__c || 0),
            deduction,
            statusText,
            statusClass
        };
    }

    formatDate(dateValue) {
        if (!dateValue) return '—';
        const date = new Date(dateValue + 'T00:00:00');
        return date.toLocaleDateString([], { day: '2-digit', month: 'short', year: 'numeric' });
    }

    get hasHistoryRows() {
        return !this.isHistoryLoading && this.historyRows.length > 0;
    }

    get noHistoryRows() {
        return !this.isHistoryLoading && this.historyRows.length === 0;
    }
}