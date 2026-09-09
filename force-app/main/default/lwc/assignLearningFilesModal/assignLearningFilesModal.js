import { LightningElement, api } from 'lwc';
import getTopLevelFolders from '@salesforce/apex/LearningAccessAdminController.getTopLevelFolders';
import getAssignableFilesTree from '@salesforce/apex/LearningAccessAdminController.getAssignableFilesTree';
import assignFilesToContact from '@salesforce/apex/LearningAccessAdminController.assignFilesToContact';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

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
    lastTreeData = null;

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