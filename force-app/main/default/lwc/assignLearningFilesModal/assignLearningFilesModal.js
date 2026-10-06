import { LightningElement, api } from 'lwc';
import getTopLevelFolders from '@salesforce/apex/LearningAccessAdminController.getTopLevelFolders';
import getAssignableFilesTree from '@salesforce/apex/LearningAccessAdminController.getAssignableFilesTree';
import assignFilesToContact from '@salesforce/apex/LearningAccessAdminController.assignFilesToContact';
import getGrantedFilesForContact from '@salesforce/apex/LearningAccessAdminController.getGrantedFilesForContact';
import revokeFileFromContact from '@salesforce/apex/LearningAccessAdminController.revokeFileFromContact';
import revokeFilesFromContact from '@salesforce/apex/LearningAccessAdminController.revokeFilesFromContact';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';

export default class AssignLearningFilesModal extends LightningElement {
    @api contactId;
    @api userName;

    searchTerm = '';
    selectedTopic = null; // Set to null instead of ''
    topicOptions = [];
    flatFolderList = [];
    expandedFolderIds = new Set();
    selectedFileIds = new Set();
    isLoading = false;
    isGrantedFilesLoading = false;
    activeTab = 'assign';
    grantedFiles = [];
    selectedGrantedFileIds = [];
    hasLoadedGrantedFiles = false;
    revokingFileId;
    isBulkRevoking = false;
    lastTreeData = null;

    get isAssignTab() { return this.activeTab === 'assign'; }
    get isGrantedFilesTab() { return this.activeTab === 'granted'; }
    get assignTabVariant() { return this.isAssignTab ? 'brand' : 'neutral'; }
    get grantedTabVariant() { return this.isGrantedFilesTab ? 'brand' : 'neutral'; }
    get hasGrantedFiles() { return this.grantedFiles.length > 0; }
    get selectedGrantedFileCount() { return this.selectedGrantedFileIds.length; }
    get hasSelectedGrantedFiles() { return this.selectedGrantedFileCount > 0; }
    get revokeSelectedLabel() { return `Revoke Selected (${this.selectedGrantedFileCount})`; }
    get isRevoking() { return Boolean(this.revokingFileId) || this.isBulkRevoking; }
    get disableRevokeSelected() { return !this.hasSelectedGrantedFiles || this.isRevoking; }
    get areAllGrantedFilesSelected() {
        return this.hasGrantedFiles && this.grantedFiles.every((file) => this.selectedGrantedFileIds.includes(file.fileId));
    }

    connectedCallback() {
        this.loadTopics();
        this.loadTree();
    }

    loadTopics() {
        getTopLevelFolders()
            .then(data => {
                this.topicOptions = [
                    { label: 'All Topics', value: null }, // Value must be null for Apex Id param
                    ...data.map(topic => ({ label: topic.folderName, value: topic.folderId }))
                ];
            })
            .catch(error => this.showToast('Error loading topics', error.body?.message || error.message, 'error'));
    }

    loadTree() {
        this.isLoading = true;
        return getAssignableFilesTree({
            contactId: this.contactId,
            searchTerm: this.searchTerm,
            topFolderId: this.selectedTopic
        })
        .then(data => {
            this.lastTreeData = data;
            this.initializeFolderExpansion(data);
            this.processTreeData(data);
        })
        .catch(error => this.showToast('Error loading files', error.body?.message || error.message, 'error'))
        .finally(() => { this.isLoading = false; });
    }

    handleShowAssignTab() {
        this.activeTab = 'assign';
    }

    async handleShowGrantedTab() {
        this.activeTab = 'granted';
        if (this.hasLoadedGrantedFiles || this.isGrantedFilesLoading) return;

        this.isGrantedFilesLoading = true;
        try {
            const rows = await getGrantedFilesForContact({ contactId: this.contactId });
            this.grantedFiles = rows.map((row) => ({
                ...row,
                grantedDateLabel: row.grantedDate ? new Date(row.grantedDate).toLocaleDateString() : '—',
                completionStatusLabel: row.completionStatus || 'Not Started',
                selected: this.selectedGrantedFileIds.includes(row.fileId)
            }));
            this.hasLoadedGrantedFiles = true;
        } catch (error) {
            this.showToast('Error loading granted files', error.body?.message || error.message, 'error');
        } finally {
            this.isGrantedFilesLoading = false;
        }
    }

    handleRefreshGrantedFiles() {
        if (this.isGrantedFilesLoading) return;
        this.hasLoadedGrantedFiles = false;
        this.handleShowGrantedTab();
    }

    handleGrantedFileSelection(event) {
        const fileId = event.currentTarget.dataset.fileId;
        const selected = event.target.checked;
        this.selectedGrantedFileIds = selected
            ? [...new Set([...this.selectedGrantedFileIds, fileId])]
            : this.selectedGrantedFileIds.filter((id) => id !== fileId);
        this.grantedFiles = this.grantedFiles.map((file) => ({
            ...file,
            selected: this.selectedGrantedFileIds.includes(file.fileId)
        }));
    }

    handleSelectAllGrantedFiles(event) {
        this.selectedGrantedFileIds = event.target.checked
            ? this.grantedFiles.map((file) => file.fileId)
            : [];
        this.grantedFiles = this.grantedFiles.map((file) => ({
            ...file,
            selected: this.selectedGrantedFileIds.includes(file.fileId)
        }));
    }

    async handleRevokeSelectedFiles() {
        if (!this.hasSelectedGrantedFiles || this.isRevoking) return;

        const selectedFiles = this.grantedFiles.filter((file) => this.selectedGrantedFileIds.includes(file.fileId));
        const confirmed = await LightningConfirm.open({
            label: 'Revoke selected file access',
            message: `Revoke access to ${selectedFiles.length} selected file(s) for ${this.userName}?`,
            theme: 'warning'
        });
        if (!confirmed) return;

        this.isBulkRevoking = true;
        const selectedFileIds = selectedFiles.map((file) => file.fileId);
        try {
            await revokeFilesFromContact({ contactId: this.contactId, fileIds: selectedFileIds });
            this.grantedFiles = this.grantedFiles.filter((file) => !this.selectedGrantedFileIds.includes(file.fileId));
            this.selectedGrantedFileIds = [];
            this.hasLoadedGrantedFiles = true;
            await this.loadTree();
            this.showToast('Access revoked', `Access revoked for ${selectedFiles.length} file(s) for ${this.userName}.`, 'success');
        } catch (error) {
            this.showToast('Could not revoke selected files', error.body?.message || error.message, 'error');
            this.hasLoadedGrantedFiles = false;
            await this.handleShowGrantedTab();
        } finally {
            this.isBulkRevoking = false;
        }
    }

    async handleRevokeFile(event) {
        const fileId = event.currentTarget.dataset.fileId;
        const selectedFile = this.grantedFiles.find((file) => file.fileId === fileId);
        if (!selectedFile || this.isRevoking) return;

        const confirmed = await LightningConfirm.open({
            label: 'Revoke file access',
            message: `Revoke access to "${selectedFile.fileName}" for ${this.userName}?`,
            theme: 'warning'
        });
        if (!confirmed) return;

        this.revokingFileId = fileId;
        try {
            await revokeFileFromContact({ contactId: this.contactId, fileId });
            this.grantedFiles = this.grantedFiles.filter((file) => file.fileId !== fileId);
            this.selectedGrantedFileIds = this.selectedGrantedFileIds.filter((id) => id !== fileId);
            this.hasLoadedGrantedFiles = true;
            await this.loadTree();
            this.showToast('Access revoked', `${selectedFile.fileName} is no longer available to ${this.userName}.`, 'success');
        } catch (error) {
            this.showToast('Could not revoke access', error.body?.message || error.message, 'error');
        } finally {
            this.revokingFileId = undefined;
        }
    }

    initializeFolderExpansion(nodes) {
        nodes.forEach(node => {
            this.expandedFolderIds.add(node.folderId);
            if (node.subFolders) {
                this.initializeFolderExpansion(node.subFolders);
            }
        });
    }

    processTreeData(treeNodes) {
        const flatList = [];

        const flatten = (nodes, depth) => {
            nodes.forEach(node => {
                const isExpanded = this.expandedFolderIds.has(node.folderId);

                flatList.push({
                    folderId: node.folderId,
                    folderName: node.folderName,
                    depth: depth,
                    style: `padding-left: ${depth * 20}px;`,
                    isExpanded: isExpanded,
                    iconName: isExpanded ? 'utility:chevrondown' : 'utility:chevronright',
                    hasFiles: node.files && node.files.length > 0,
                    hasSubFolders: node.subFolders && node.subFolders.length > 0,
                    files: (node.files || []).map(f => ({
                        ...f,
                        fileStyle: `padding-left: ${(depth + 1) * 20}px;`,
                        selected: this.selectedFileIds.has(f.fileId)
                    }))
                });

                if (isExpanded && node.subFolders && node.subFolders.length > 0) {
                    flatten(node.subFolders, depth + 1);
                }
            });
        };

        flatten(treeNodes, 0);
        this.flatFolderList = flatList;
    }

    handleSearch(event) {
        this.searchTerm = event.target.value;
        this.loadTree();
    }

    handleTopicChange(event) {
        // Ensure empty selection sets property back to null
        this.selectedTopic = event.detail.value || null;
        this.loadTree();
    }

    handleFolderToggle(event) {
        const folderId = event.currentTarget.dataset.id;
        if (this.expandedFolderIds.has(folderId)) {
            this.expandedFolderIds.delete(folderId);
        } else {
            this.expandedFolderIds.add(folderId);
        }

        if (this.lastTreeData) {
            this.processTreeData(this.lastTreeData);
        }
    }

    handleFileToggle(event) {
        const fileId = event.target.dataset.id;
        const checked = event.target.checked;

        if (checked) {
            this.selectedFileIds.add(fileId);
        } else {
            this.selectedFileIds.delete(fileId);
        }

        if (this.lastTreeData) {
            this.processTreeData(this.lastTreeData);
        }
    }

    get hasData() {
        return this.flatFolderList && this.flatFolderList.length > 0;
    }

    get noneSelected() {
        return this.selectedFileIds.size === 0;
    }

    get assignButtonLabel() {
        const count = this.selectedFileIds.size;
        return count > 0 ? `Assign (${count})` : 'Assign';
    }

    async handleAssign() {
        const fileIdsToAssign = Array.from(this.selectedFileIds);
        this.isLoading = true;

        try {
            await assignFilesToContact({ contactId: this.contactId, fileIds: fileIdsToAssign });
            this.showToast('Success', `${fileIdsToAssign.length} file(s) assigned.`, 'success');
            this.selectedFileIds.clear();
            this.hasLoadedGrantedFiles = false;
            this.handleClose(); // no need to reload here — modal is closing anyway
        } catch (error) {
            this.showToast('Error assigning files', error.body?.message || error.message, 'error');
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