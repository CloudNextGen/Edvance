import { LightningElement, track } from 'lwc';
import getDriveItems from '@salesforce/apex/DriveBrowserController.getDriveItems';

export default class DriveBrowser extends LightningElement {

    @track items = [];
    @track breadcrumbs = [{ id: null, name: 'Learning Content' }];
    isLoading = true;
    errorMessage;

    connectedCallback() {
        this.loadFolder(null);
    }

    loadFolder(folderId) {
        this.isLoading = true;
        this.errorMessage = null;

        getDriveItems({ folderId: folderId })
            .then(result => {
                this.items = result.map(item => ({
                    ...item,
                    rowClass: item.isFolder ? 'drive-row drive-row-folder' : 'drive-row drive-row-file'
                }));
            })
            .catch(error => {
                this.errorMessage = error.body ? error.body.message : 'Failed to load Drive content.';
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleItemClick(event) {
        const id = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name;
        const isFolder = event.currentTarget.dataset.folder === 'true';
        const webViewLink = event.currentTarget.dataset.link;

        if (isFolder) {
            this.breadcrumbs = [...this.breadcrumbs, { id, name }];
            this.loadFolder(id);
        } else if (webViewLink) {
            window.open(webViewLink, '_blank', 'noopener,noreferrer');
        }
    }

    handleBreadcrumbClick(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const target = this.breadcrumbs[index];

        this.breadcrumbs = this.breadcrumbs.slice(0, index + 1);
        this.loadFolder(target.id);
    }

    get breadcrumbItems() {
        return this.breadcrumbs.map((crumb, idx) => ({
            ...crumb,
            index: idx,
            isLast: idx === this.breadcrumbs.length - 1
        }));
    }

    get hasNoItems() {
        return !this.isLoading && !this.errorMessage && this.items.length === 0;
    }
}