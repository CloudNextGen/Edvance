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
            this.generalList = this.formatInstructionItems(data.generalInstructions);
            this.roleList = this.formatInstructionItems(data.roleInstructions);
            this.roleName = data.userRole || '';
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Error loading instructions';
            this.generalList = [];
            this.roleList = [];
        }
    }

    formatInstructionItems(instructionItems) {
        if (!instructionItems || instructionItems.length === 0) return [];
        return instructionItems.map(instructionItem => {
            let instructionContent = instructionItem.Instructions__c || '';
            
            // Check if string contains HTML tags
            const containsHtmlTags = /<[a-z][\s\S]*>/i.test(instructionContent);

            if (containsHtmlTags) {
                // Remove redundant whitespace between HTML tags so li spacing doesn't blow up
                instructionContent = instructionContent.replace(/>\s+</g, '><').trim();
            } else {
                // If it's plain text with Enter keys, turn newlines into proper <br/> tags
                instructionContent = instructionContent.replace(/\r?\n/g, '<br/>');
            }

            return {
                ...instructionItem,
                formattedInstructions: instructionContent
            };
        });
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