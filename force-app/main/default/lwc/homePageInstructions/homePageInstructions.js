import { LightningElement, wire } from 'lwc';
import getInstructions from '@salesforce/apex/InstructionController.getInstructions';

export default class HomePageInstructions extends LightningElement {
    generalList = [];
    roleList = [];
    roleName = '';
    error;
    isLoading = true;

    @wire(getInstructions)
    wiredInstructions({ error, data }) {
        this.isLoading = false;
        if (data) {
            this.generalList = data.generalInstructions || [];
            this.roleList = data.roleInstructions || [];
            this.roleName = data.userRole || '';
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Error loading instructions';
            this.generalList = [];
            this.roleList = [];
        }
    }

    get hasGeneral() {
        return this.generalList && this.generalList.length > 0;
    }

    get hasRole() {
        return this.roleList && this.roleList.length > 0;
    }

    get hasAnyInstructions() {
        return this.hasGeneral || this.hasRole;
    }
}