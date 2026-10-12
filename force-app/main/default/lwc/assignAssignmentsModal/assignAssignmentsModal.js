import { LightningElement, api } from 'lwc';
import getAssignableAssignmentsTree from '@salesforce/apex/Assignmentadmincontroller.getAssignableAssignmentsTree';
import assignAssignmentsToContact from '@salesforce/apex/Assignmentadmincontroller.assignAssignmentsToContact';
import reassignAssignment from '@salesforce/apex/Assignmentadmincontroller.reassignAssignment';
import revokeAssignmentFromContact from '@salesforce/apex/Assignmentadmincontroller.revokeAssignmentFromContact';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';

export default class AssignAssignmentsModal extends LightningElement {
    @api contactId;
    @api userName;

    searchTerm = '';
    flatCategoryList = [];
    expandedCategoryIds = new Set();
    selectedAssignmentIds = new Set();
    isLoading = false;
    lastTreeData = null;

    connectedCallback() {
        this.loadTree();
    }

    loadTree() {
        this.isLoading = true;
        return getAssignableAssignmentsTree({
            contactId: this.contactId,
            searchTerm: this.searchTerm
        })
        .then(data => {
            this.lastTreeData = data;
            this.initializeCategoryExpansion(data);
            this.processTreeData(data);
        })
        .catch(error => this.showToast('Error loading assignments', error.body?.message || error.message, 'error'))
        .finally(() => { this.isLoading = false; });
    }

    initializeCategoryExpansion(nodes) {
        nodes.forEach(node => {
            this.expandedCategoryIds.add(node.categoryId);
        });
    }

    processTreeData(categoryNodes) {
        this.flatCategoryList = categoryNodes.map(node => {
            const isExpanded = this.expandedCategoryIds.has(node.categoryId);
            return {
                categoryId: node.categoryId,
                categoryName: node.categoryName,
                isExpanded: isExpanded,
                iconName: isExpanded ? 'utility:chevrondown' : 'utility:chevronright',
                hasAssignments: node.assignments && node.assignments.length > 0,
                assignments: (node.assignments || []).map(asm => this.decorateAssignment(asm))
            };
        });
    }

    decorateAssignment(asm) {
        const isNotAssigned = asm.status === 'Not Assigned';
        return {
            ...asm,
            selected: this.selectedAssignmentIds.has(asm.assignmentId),
            isSelectable: isNotAssigned,
            statusBadgeClass: this.badgeClassFor(asm.status),
            statusLabel: this.badgeLabelFor(asm.status)
        };
    }

    badgeClassFor(status) {
        if (status === 'Completed') return 'slds-badge slds-theme_success';
        if (status === 'Locked') return 'slds-badge slds-theme_error';
        if (status === 'Eligible') return 'slds-badge';
        return 'slds-badge';
    }

    badgeLabelFor(status) {
        if (status === 'Eligible') return 'Already Assigned';
        return status; // 'Completed' | 'Locked'
    }

    handleSearch(event) {
        this.searchTerm = event.target.value;
        this.loadTree();
    }

    handleCategoryToggle(event) {
        const categoryId = event.currentTarget.dataset.id;
        if (this.expandedCategoryIds.has(categoryId)) {
            this.expandedCategoryIds.delete(categoryId);
        } else {
            this.expandedCategoryIds.add(categoryId);
        }
        if (this.lastTreeData) {
            this.processTreeData(this.lastTreeData);
        }
    }

    handleAssignmentToggle(event) {
        const assignmentId = event.target.dataset.id;
        const checked = event.target.checked;

        if (checked) {
            this.selectedAssignmentIds.add(assignmentId);
        } else {
            this.selectedAssignmentIds.delete(assignmentId);
        }

        if (this.lastTreeData) {
            this.processTreeData(this.lastTreeData);
        }
    }

    async handleReassign(event) {
        const eligibilityId = event.currentTarget.dataset.eligibilityId;
        const assignmentName = event.currentTarget.dataset.name;
        this.isLoading = true;

        try {
            await reassignAssignment({ eligibilityId });
            this.showToast('Success', `${assignmentName} reassigned — eligible for a new attempt.`, 'success');
            await this.loadTree();
        } catch (error) {
            this.showToast('Error reassigning', error.body?.message || error.message, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleRevoke(event) {
        const eligibilityId = event.currentTarget.dataset.eligibilityId;
        const assignmentName = event.currentTarget.dataset.name;
        const confirmed = await LightningConfirm.open({
            label: 'Revoke assignment access',
            message: `Revoke access to "${assignmentName}" for ${this.userName}?`,
            theme: 'warning'
        });
        if (!confirmed) return;

        this.isLoading = true;
        try {
            await revokeAssignmentFromContact({ contactId: this.contactId, eligibilityId });
            this.showToast('Access revoked', `${assignmentName} is no longer available to ${this.userName}.`, 'success');
            await this.loadTree();
        } catch (error) {
            this.showToast('Could not revoke assignment access', error.body?.message || error.message, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    get hasData() {
        return this.flatCategoryList && this.flatCategoryList.length > 0;
    }

    get noneSelected() {
        return this.selectedAssignmentIds.size === 0;
    }

    get assignButtonLabel() {
        const count = this.selectedAssignmentIds.size;
        return count > 0 ? `Assign (${count})` : 'Assign';
    }

    async handleAssign() {
        const assignmentIdsToAssign = Array.from(this.selectedAssignmentIds);
        this.isLoading = true;

        try {
            await assignAssignmentsToContact({ contactId: this.contactId, assignmentIds: assignmentIdsToAssign });
            this.showToast('Success', `${assignmentIdsToAssign.length} assignment(s) assigned.`, 'success');
            this.selectedAssignmentIds.clear();
            this.handleClose();
        } catch (error) {
            this.showToast('Error assigning', error.body?.message || error.message, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}