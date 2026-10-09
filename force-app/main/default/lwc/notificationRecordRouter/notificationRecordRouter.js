import { LightningElement, api, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import canViewAttendance from '@salesforce/customPermission/View_Attendance';
import getNotificationRecordType from '@salesforce/apex/PortalNotificationRouterController.getNotificationRecordType';

export default class NotificationRecordRouter extends LightningElement {
    @api recordId;
    @api objectApiName;

    pageReference;
    isChecking = false;
    routingError;
    _lastRoutedRecordKey;
    _isCheckingRecord = false;

    @wire(CurrentPageReference)
    wiredPageReference(pageReference) {
        this.pageReference = pageReference;
    }

    get resolvedRecordId() {
        const state = this.pageReference?.state || {};
        const attributes = this.pageReference?.attributes || {};
        const pageRecordId = state.recordId || state.recordID || state.recordid ||
            attributes.recordId || attributes.recordID;
        if (pageRecordId) {
            return pageRecordId;
        }

        const detailRouteMatch = window.location.pathname.match(/\/s\/detail\/([a-zA-Z0-9]{15,18})(?:\/|$)/);
        return detailRouteMatch ? detailRouteMatch[1] : this.recordId;
    }

    get showRedirectMessage() {
        return this.isChecking || Boolean(this.routingError);
    }

    renderedCallback() {
        const targetId = this.resolvedRecordId;
        if (!targetId || this._isCheckingRecord) {
            return;
        }

        const recordKey = `${this.objectApiName || ''}:${targetId}`;
        if (recordKey === this._lastRoutedRecordKey) {
            return;
        }
        this._lastRoutedRecordKey = recordKey;
        this._isCheckingRecord = true;
        this.isChecking = true;
        getNotificationRecordType({ recordId: targetId }).then((recordType) => {
            if (recordType === 'Attendance_Log__c') {
                if (!canViewAttendance) {
                    this.routingError = 'You do not have attendance review access.';
                    this.isChecking = false;
                    return;
                }
                this.redirectTo(`/s/dashboard?c__screen=appeals&c__appealId=${encodeURIComponent(targetId)}`);
                return;
            }

            if (recordType === 'Case') {
                this.redirectTo(`/s/all-requests?c__caseId=${encodeURIComponent(targetId)}`);
                return;
            }

            if (!recordType) {
                this.isChecking = false;
                return;
            }
        }).catch((error) => {
            this._isCheckingRecord = false;
            this.isChecking = false;
            this.routingError = error?.body?.message || error?.message ||
                'Could not verify this notification record.';
        });
    }

    redirectTo(path) {
        const currentPath = window.location.pathname;
        const detailRouteIndex = currentPath.indexOf('/s/detail/');
        const siteRoot = detailRouteIndex >= 0
            ? currentPath.substring(0, detailRouteIndex)
            : currentPath.replace(/\/s\/?$/, '');
        window.location.assign(`${siteRoot}${path}`);
    }
}