import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCaseComments from '@salesforce/apex/PortalRequestService.getCaseComments';
import addCaseComment from '@salesforce/apex/PortalRequestService.addCaseComment';

export default class CaseCommentThread extends LightningElement {
    @api recordId;

    _showSubmitButton = false;

    @api
    get showSubmitButton() {
        return this._showSubmitButton;
    }
    set showSubmitButton(value) {
        this._showSubmitButton = value === true || value === 'true';
    }

    wiredResult;
    newComment = '';
    isPosting = false;
    errorMessage = '';

    @wire(getCaseComments, { caseId: '$recordId' })
    wiredComments(result) {
        this.wiredResult = result;
        if (result.error) {
            this.errorMessage = result.error?.body?.message ?? 'Could not load comments.';
        } else if (result.data) {
            this.errorMessage = '';
        }
    }

    get comments() {
        if (!this.wiredResult?.data) return [];
        return this.wiredResult.data.map((c) => ({
            id: c.id,
            body: c.commentBody,
            authorName: c.authorName || 'Unknown',
            date: c.createdDate
                ? new Date(c.createdDate).toLocaleString([], {
                      day: '2-digit',
                      month: 'short',
                      year: 'numeric',
                      hour: '2-digit',
                      minute: '2-digit'
                  })
                : ''
        }));
    }

    get hasComments() {
        return this.comments.length > 0;
    }

    get isLoading() {
        return !this.wiredResult;
    }

    get isPostDisabled() {
        return this.isPosting || !this.newComment || !this.newComment.trim();
    }

    @api
    get draftComment() {
        return this.newComment ? this.newComment.trim() : '';
    }

    @api
    clearDraft() {
        this.newComment = '';
    }

    @api
    async refresh() {
        if (this.wiredResult) {
            await refreshApex(this.wiredResult);
        }
    }

    handleCommentChange(event) {
        this.newComment = event.target.value;
    }

    async handlePostComment() {
        if (!this.recordId || !this.newComment || !this.newComment.trim()) return;

        this.isPosting = true;
        this.errorMessage = '';
        try {
            await addCaseComment({ caseId: this.recordId, commentBody: this.newComment });
            this.newComment = '';
            await refreshApex(this.wiredResult);

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Comment Added',
                    message: 'Your comment has been posted.',
                    variant: 'success'
                })
            );

            this.dispatchEvent(new CustomEvent('commentposted', { detail: { caseId: this.recordId } }));
        } catch (error) {
            this.errorMessage = error?.body?.message || 'Unable to post comment. Please try again.';
        } finally {
            this.isPosting = false;
        }
    }
}