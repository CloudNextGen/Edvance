import { LightningElement, wire } from 'lwc';
import getInstructions from '@salesforce/apex/InstructionController.getInstructions';

export default class HomePageInstructions extends LightningElement {
    instructions = [];
    error;
    isLoading = true;

    @wire(getInstructions)
    wiredInstructions({ error, data }) {
        this.isLoading = false;
        if (data) {
            this.instructions = data;
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Error loading instructions';
            this.instructions = [];
        }
    }

    get hasInstructions() {
        return this.instructions && this.instructions.length > 0;
    }
}