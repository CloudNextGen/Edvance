public without sharing class InstructionController {

    private static final String PERM_HR = 'Portal_HR_Access';
    private static final String PERM_MENTOR = 'Portal_Mentor_Access';
    private static final String PERM_TEAM_MEMBER = 'Portal_Team_Member_Access';

    public class InstructionWrapper {
        @AuraEnabled public String userRole;
        @AuraEnabled public List<Instruction_Visiblity__mdt> generalInstructions;
        @AuraEnabled public List<Instruction_Visiblity__mdt> roleInstructions;

        public InstructionWrapper() {
            this.generalInstructions = new List<Instruction_Visiblity__mdt>();
            this.roleInstructions = new List<Instruction_Visiblity__mdt>();
        }
    }

    @AuraEnabled(cacheable=true)
    public static InstructionWrapper getInstructions() {
        try {
            InstructionWrapper wrapper = new InstructionWrapper();

            Boolean isHR = FeatureManagement.checkPermission(PERM_HR);
            Boolean isMentor = FeatureManagement.checkPermission(PERM_MENTOR);
            Boolean hasTeamMember = FeatureManagement.checkPermission(PERM_TEAM_MEMBER);
            Boolean isPureTeamMember = hasTeamMember && !isMentor;

            if (isHR) {
                wrapper.userRole = 'HR Portal';
            } else if (isMentor) {
                wrapper.userRole = 'Mentor';
            } else if (isPureTeamMember) {
                wrapper.userRole = 'Team Member';
            } else {
                wrapper.userRole = 'General';
            }

            List<Instruction_Visiblity__mdt> allRecords = [
                SELECT Id, MasterLabel, DeveloperName, Instructions__c, ORDER__c, 
                       All__c, HR__c, MENTOR__c, TEAM_MEMBER__c 
                FROM Instruction_Visiblity__mdt 
                ORDER BY ORDER__c ASC NULLS LAST
            ];

            for (Instruction_Visiblity__mdt item : allRecords) {
                if (item.All__c == true) {
                    wrapper.generalInstructions.add(item);
                    continue;
                }

                Boolean canView = false;
                if (item.HR__c == true && isHR) {
                    canView = true;
                }
                if (item.MENTOR__c == true && isMentor) {
                    canView = true;
                }
                if (item.TEAM_MEMBER__c == true && isPureTeamMember) {
                    canView = true;
                }

                if (canView) {
                    wrapper.roleInstructions.add(item);
                }
            }

            return wrapper;

        } catch (Exception e) {
            throw new AuraHandledException('Unable to retrieve instructions: ' + e.getMessage());
        }
    }
}