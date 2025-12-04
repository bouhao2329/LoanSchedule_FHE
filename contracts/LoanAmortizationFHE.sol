// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract LoanAmortizationFHE is SepoliaConfig {
    struct EncryptedLoan {
        uint256 id;
        address borrower;
        euint32 encryptedPrincipal;    // Encrypted loan amount
        euint32 encryptedInterestRate;  // Encrypted annual interest rate (basis points)
        euint32 encryptedTerm;          // Encrypted loan term (months)
        euint32 encryptedExtraPayment;  // Encrypted extra payment amount
        uint256 timestamp;
    }
    
    struct AmortizationSchedule {
        euint32 encryptedMonthlyPayment; // Encrypted monthly payment
        euint32 encryptedTotalInterest;  // Encrypted total interest
        euint32 encryptedPayoffTime;     // Encrypted payoff time (months)
        bool isCalculated;
    }
    
    struct DecryptedSchedule {
        uint32 monthlyPayment;
        uint32 totalInterest;
        uint32 payoffTime;
        bool isRevealed;
    }

    uint256 public loanCount;
    mapping(uint256 => EncryptedLoan) public encryptedLoans;
    mapping(uint256 => AmortizationSchedule) public amortizationSchedules;
    mapping(uint256 => DecryptedSchedule) public decryptedSchedules;
    
    mapping(address => uint256[]) private borrowerLoans;
    mapping(address => bool) private financialAdvisors;
    
    mapping(uint256 => uint256) private requestToLoanId;
    
    event LoanSubmitted(uint256 indexed id, address indexed borrower);
    event ScheduleCalculated(uint256 indexed id);
    event ScheduleDecrypted(uint256 indexed id);
    
    address public platformAdmin;
    
    modifier onlyAdmin() {
        require(msg.sender == platformAdmin, "Not admin");
        _;
    }
    
    modifier onlyAdvisor() {
        require(financialAdvisors[msg.sender], "Not authorized");
        _;
    }
    
    constructor() {
        platformAdmin = msg.sender;
    }
    
    /// @notice Authorize a financial advisor
    function authorizeAdvisor(address advisor) public onlyAdmin {
        financialAdvisors[advisor] = true;
    }
    
    /// @notice Submit encrypted loan application
    function submitEncryptedLoan(
        euint32 encryptedPrincipal,
        euint32 encryptedInterestRate,
        euint32 encryptedTerm,
        euint32 encryptedExtraPayment
    ) public {
        loanCount += 1;
        uint256 newId = loanCount;
        
        encryptedLoans[newId] = EncryptedLoan({
            id: newId,
            borrower: msg.sender,
            encryptedPrincipal: encryptedPrincipal,
            encryptedInterestRate: encryptedInterestRate,
            encryptedTerm: encryptedTerm,
            encryptedExtraPayment: encryptedExtraPayment,
            timestamp: block.timestamp
        });
        
        amortizationSchedules[newId] = AmortizationSchedule({
            encryptedMonthlyPayment: FHE.asEuint32(0),
            encryptedTotalInterest: FHE.asEuint32(0),
            encryptedPayoffTime: FHE.asEuint32(0),
            isCalculated: false
        });
        
        decryptedSchedules[newId] = DecryptedSchedule({
            monthlyPayment: 0,
            totalInterest: 0,
            payoffTime: 0,
            isRevealed: false
        });
        
        borrowerLoans[msg.sender].push(newId);
        emit LoanSubmitted(newId, msg.sender);
    }
    
    /// @notice Calculate amortization schedule
    function calculateAmortization(uint256 loanId) public onlyAdvisor {
        EncryptedLoan storage loan = encryptedLoans[loanId];
        require(!amortizationSchedules[loanId].isCalculated, "Already calculated");
        
        // Calculate monthly interest rate
        euint32 monthlyRate = FHE.div(loan.encryptedInterestRate, FHE.asEuint32(1200)); // Divided by 12 * 100
        
        // Calculate monthly payment
        euint32 numerator = FHE.mul(
            FHE.mul(loan.encryptedPrincipal, monthlyRate),
            FHE.pow(FHE.add(FHE.asEuint32(1), monthlyRate), loan.encryptedTerm)
        );
        
        euint32 denominator = FHE.sub(
            FHE.pow(FHE.add(FHE.asEuint32(1), monthlyRate), loan.encryptedTerm),
            FHE.asEuint32(1)
        );
        
        euint32 monthlyPayment = FHE.div(numerator, denominator);
        
        // Calculate total interest
        euint32 totalPayment = FHE.mul(monthlyPayment, loan.encryptedTerm);
        euint32 totalInterest = FHE.sub(totalPayment, loan.encryptedPrincipal);
        
        // Calculate payoff time with extra payments
        euint32 extraPayment = loan.encryptedExtraPayment;
        euint32 effectivePayment = FHE.add(monthlyPayment, extraPayment);
        
        euint32 payoffTime = FHE.div(
            loan.encryptedPrincipal,
            effectivePayment
        );
        
        amortizationSchedules[loanId] = AmortizationSchedule({
            encryptedMonthlyPayment: monthlyPayment,
            encryptedTotalInterest: totalInterest,
            encryptedPayoffTime: payoffTime,
            isCalculated: true
        });
        
        emit ScheduleCalculated(loanId);
    }
    
    /// @notice Request decryption of amortization schedule
    function requestScheduleDecryption(uint256 loanId) public {
        require(encryptedLoans[loanId].borrower == msg.sender, "Not borrower");
        require(!decryptedSchedules[loanId].isRevealed, "Already decrypted");
        require(amortizationSchedules[loanId].isCalculated, "Schedule not calculated");
        
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        
        bytes32[] memory ciphertexts = new bytes32[](3);
        ciphertexts[0] = FHE.toBytes32(schedule.encryptedMonthlyPayment);
        ciphertexts[1] = FHE.toBytes32(schedule.encryptedTotalInterest);
        ciphertexts[2] = FHE.toBytes32(schedule.encryptedPayoffTime);
        
        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptAmortizationSchedule.selector);
        requestToLoanId[reqId] = loanId;
    }
    
    /// @notice Process decrypted amortization schedule
    function decryptAmortizationSchedule(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 loanId = requestToLoanId[requestId];
        require(loanId != 0, "Invalid request");
        
        AmortizationSchedule storage aSchedule = amortizationSchedules[loanId];
        DecryptedSchedule storage dSchedule = decryptedSchedules[loanId];
        require(aSchedule.isCalculated, "Schedule not calculated");
        require(!dSchedule.isRevealed, "Already decrypted");
        
        FHE.checkSignatures(requestId, cleartexts, proof);
        
        (uint32 monthlyPayment, uint32 totalInterest, uint32 payoffTime) = 
            abi.decode(cleartexts, (uint32, uint32, uint32));
        
        dSchedule.monthlyPayment = monthlyPayment;
        dSchedule.totalInterest = totalInterest;
        dSchedule.payoffTime = payoffTime;
        dSchedule.isRevealed = true;
        
        emit ScheduleDecrypted(loanId);
    }
    
    /// @notice Calculate interest savings
    function calculateInterestSavings(uint256 loanId) public view returns (euint32) {
        EncryptedLoan storage loan = encryptedLoans[loanId];
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        // Calculate interest without extra payments
        euint32 baseTotalInterest = schedule.encryptedTotalInterest;
        
        // Calculate interest with extra payments
        euint32 extraPayment = loan.encryptedExtraPayment;
        euint32 effectivePayment = FHE.add(schedule.encryptedMonthlyPayment, extraPayment);
        euint32 payoffTime = schedule.encryptedPayoffTime;
        
        euint32 totalPaymentWithExtra = FHE.mul(effectivePayment, payoffTime);
        euint32 totalInterestWithExtra = FHE.sub(totalPaymentWithExtra, loan.encryptedPrincipal);
        
        return FHE.sub(baseTotalInterest, totalInterestWithExtra);
    }
    
    /// @notice Calculate affordability score
    function calculateAffordability(uint256 loanId) public view returns (euint32) {
        EncryptedLoan storage loan = encryptedLoans[loanId];
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        // Affordability = (income - monthly payment) / income * 100
        // Simplified: assume income is principal / 10
        euint32 estimatedIncome = FHE.div(loan.encryptedPrincipal, FHE.asEuint32(10));
        euint32 disposableIncome = FHE.sub(estimatedIncome, schedule.encryptedMonthlyPayment);
        
        return FHE.div(
            FHE.mul(disposableIncome, FHE.asEuint32(100)),
            estimatedIncome
        );
    }
    
    /// @notice Optimize payment strategy
    function optimizePaymentStrategy(uint256 loanId) public view returns (euint32) {
        EncryptedLoan storage loan = encryptedLoans[loanId];
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        // Strategy: increase extra payment if savings are significant
        euint32 savings = calculateInterestSavings(loanId);
        euint32 savingsRatio = FHE.div(
            FHE.mul(savings, FHE.asEuint32(100)),
            schedule.encryptedTotalInterest
        );
        
        return FHE.cmux(
            FHE.gt(savingsRatio, FHE.asEuint32(15)), // More than 15% savings
            FHE.add(loan.encryptedExtraPayment, FHE.asEuint32(100)),
            loan.encryptedExtraPayment
        );
    }
    
    /// @notice Calculate debt-to-income ratio
    function calculateDebtToIncome(uint256 loanId) public view returns (euint32) {
        EncryptedLoan storage loan = encryptedLoans[loanId];
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        // Simplified: assume income is principal / 10
        euint32 estimatedIncome = FHE.div(loan.encryptedPrincipal, FHE.asEuint32(10));
        
        return FHE.div(
            FHE.mul(schedule.encryptedMonthlyPayment, FHE.asEuint32(100)),
            estimatedIncome
        );
    }
    
    /// @notice Estimate early payoff impact
    function estimateEarlyPayoffImpact(uint256 loanId, euint32 additionalPayment) public view returns (euint32) {
        EncryptedLoan storage loan = encryptedLoans[loanId];
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        euint32 newExtraPayment = FHE.add(loan.encryptedExtraPayment, additionalPayment);
        euint32 effectivePayment = FHE.add(schedule.encryptedMonthlyPayment, newExtraPayment);
        
        euint32 newPayoffTime = FHE.div(loan.encryptedPrincipal, effectivePayment);
        euint32 totalPayment = FHE.mul(effectivePayment, newPayoffTime);
        euint32 totalInterest = FHE.sub(totalPayment, loan.encryptedPrincipal);
        
        return FHE.sub(schedule.encryptedTotalInterest, totalInterest);
    }
    
    /// @notice Calculate loan health score
    function calculateLoanHealth(uint256 loanId) public view returns (euint32) {
        euint32 dti = calculateDebtToIncome(loanId);
        euint32 affordability = calculateAffordability(loanId);
        
        return FHE.div(
            FHE.add(
                FHE.sub(FHE.asEuint32(100), dti),
                affordability
            ),
            FHE.asEuint32(2)
        );
    }
    
    /// @notice Get encrypted loan details
    function getEncryptedLoan(uint256 loanId) public view returns (
        address borrower,
        euint32 encryptedPrincipal,
        euint32 encryptedInterestRate,
        euint32 encryptedTerm,
        euint32 encryptedExtraPayment,
        uint256 timestamp
    ) {
        EncryptedLoan storage l = encryptedLoans[loanId];
        return (
            l.borrower,
            l.encryptedPrincipal,
            l.encryptedInterestRate,
            l.encryptedTerm,
            l.encryptedExtraPayment,
            l.timestamp
        );
    }
    
    /// @notice Get encrypted amortization schedule
    function getEncryptedSchedule(uint256 loanId) public view returns (
        euint32 encryptedMonthlyPayment,
        euint32 encryptedTotalInterest,
        euint32 encryptedPayoffTime,
        bool isCalculated
    ) {
        AmortizationSchedule storage s = amortizationSchedules[loanId];
        return (
            s.encryptedMonthlyPayment,
            s.encryptedTotalInterest,
            s.encryptedPayoffTime,
            s.isCalculated
        );
    }
    
    /// @notice Get decrypted schedule
    function getDecryptedSchedule(uint256 loanId) public view returns (
        uint32 monthlyPayment,
        uint32 totalInterest,
        uint32 payoffTime,
        bool isRevealed
    ) {
        DecryptedSchedule storage s = decryptedSchedules[loanId];
        return (s.monthlyPayment, s.totalInterest, s.payoffTime, s.isRevealed);
    }
    
    /// @notice Calculate refinancing benefit
    function calculateRefinancingBenefit(uint256 loanId, euint32 newRate) public view returns (euint32) {
        EncryptedLoan storage loan = encryptedLoans[loanId];
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        // Calculate interest with new rate
        euint32 newMonthlyRate = FHE.div(newRate, FHE.asEuint32(1200));
        euint32 newMonthlyPayment = FHE.div(
            FHE.mul(
                FHE.mul(loan.encryptedPrincipal, newMonthlyRate),
                FHE.pow(FHE.add(FHE.asEuint32(1), newMonthlyRate), loan.encryptedTerm)
            ),
            FHE.sub(
                FHE.pow(FHE.add(FHE.asEuint32(1), newMonthlyRate), loan.encryptedTerm),
                FHE.asEuint32(1)
            )
        );
        
        euint32 newTotalInterest = FHE.sub(
            FHE.mul(newMonthlyPayment, loan.encryptedTerm),
            loan.encryptedPrincipal
        );
        
        return FHE.sub(schedule.encryptedTotalInterest, newTotalInterest);
    }
    
    /// @notice Calculate payment shock risk
    function calculatePaymentShockRisk(uint256 loanId) public view returns (euint32) {
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        // Risk increases with higher monthly payment relative to loan size
        return FHE.div(
            FHE.mul(schedule.encryptedMonthlyPayment, FHE.asEuint32(100)),
            encryptedLoans[loanId].encryptedPrincipal
        );
    }
    
    /// @notice Optimize for financial goals
    function optimizeForGoals(uint256 loanId, euint32 goalTime) public view returns (euint32) {
        EncryptedLoan storage loan = encryptedLoans[loanId];
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        // Calculate required payment to meet goal time
        return FHE.div(loan.encryptedPrincipal, goalTime);
    }
    
    /// @notice Calculate interest sensitivity
    function calculateInterestSensitivity(uint256 loanId) public view returns (euint32) {
        EncryptedLoan storage loan = encryptedLoans[loanId];
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        // Sensitivity = change in payment per 1% rate change
        euint32 rateChange = FHE.asEuint32(100); // 1% in basis points
        euint32 newRate = FHE.add(loan.encryptedInterestRate, rateChange);
        
        euint32 newMonthlyRate = FHE.div(newRate, FHE.asEuint32(1200));
        euint32 newMonthlyPayment = FHE.div(
            FHE.mul(
                FHE.mul(loan.encryptedPrincipal, newMonthlyRate),
                FHE.pow(FHE.add(FHE.asEuint32(1), newMonthlyRate), loan.encryptedTerm)
            ),
            FHE.sub(
                FHE.pow(FHE.add(FHE.asEuint32(1), newMonthlyRate), loan.encryptedTerm),
                FHE.asEuint32(1)
            )
        );
        
        return FHE.sub(newMonthlyPayment, schedule.encryptedMonthlyPayment);
    }
    
    /// @notice Estimate tax benefit
    function estimateTaxBenefit(uint256 loanId) public view returns (euint32) {
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        // Tax benefit = interest * tax rate (assume 25%)
        return FHE.div(schedule.encryptedTotalInterest, FHE.asEuint32(4));
    }
    
    /// @notice Calculate loan liquidity
    function calculateLoanLiquidity(uint256 loanId) public view returns (euint32) {
        EncryptedLoan storage loan = encryptedLoans[loanId];
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        // Liquidity = principal / (monthly payment * 6)
        return FHE.div(
            loan.encryptedPrincipal,
            FHE.mul(schedule.encryptedMonthlyPayment, FHE.asEuint32(6))
        );
    }
    
    /// @notice Detect overleveraging
    function detectOverleveraging(uint256 loanId) public view returns (ebool) {
        euint32 dti = calculateDebtToIncome(loanId);
        return FHE.gt(dti, FHE.asEuint32(40)); // DTI > 40% is risky
    }
    
    /// @notice Calculate financial flexibility
    function calculateFinancialFlexibility(uint256 loanId) public view returns (euint32) {
        euint32 affordability = calculateAffordability(loanId);
        euint32 loanHealth = calculateLoanHealth(loanId);
        
        return FHE.div(
            FHE.add(affordability, loanHealth),
            FHE.asEuint32(2)
        );
    }
    
    /// @notice Optimize for cash flow
    function optimizeForCashFlow(uint256 loanId) public view returns (euint32) {
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        // Target: reduce monthly payment by 10%
        return FHE.div(
            FHE.mul(schedule.encryptedMonthlyPayment, FHE.asEuint32(90)),
            FHE.asEuint32(100)
        );
    }
    
    /// @notice Calculate prepayment penalty risk
    function calculatePrepaymentRisk(uint256 loanId) public view returns (euint32) {
        EncryptedLoan storage loan = encryptedLoans[loanId];
        return FHE.div(
            FHE.mul(loan.encryptedExtraPayment, FHE.asEuint32(100)),
            loan.encryptedPrincipal
        );
    }
    
    /// @notice Estimate net cost of borrowing
    function estimateNetCost(uint256 loanId) public view returns (euint32) {
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        euint32 taxBenefit = estimateTaxBenefit(loanId);
        return FHE.sub(schedule.encryptedTotalInterest, taxBenefit);
    }
    
    /// @notice Calculate loan efficiency
    function calculateLoanEfficiency(uint256 loanId) public view returns (euint32) {
        EncryptedLoan storage loan = encryptedLoans[loanId];
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        // Efficiency = principal / total payment
        return FHE.div(
            FHE.mul(loan.encryptedPrincipal, FHE.asEuint32(100)),
            FHE.add(loan.encryptedPrincipal, schedule.encryptedTotalInterest)
        );
    }
    
    /// @notice Generate personalized advice
    function generatePersonalizedAdvice(uint256 loanId) public view returns (euint32) {
        euint32 savings = calculateInterestSavings(loanId);
        euint32 risk = calculatePaymentShockRisk(loanId);
        
        return FHE.cmux(
            FHE.gt(savings, FHE.asEuint32(1000)),
            FHE.asEuint32(1), // Recommend extra payments
            FHE.cmux(
                FHE.gt(risk, FHE.asEuint32(15)),
                FHE.asEuint32(2), // Recommend refinancing
                FHE.asEuint32(3)  // Maintain current plan
            )
        );
    }
    
    /// @notice Protect financial privacy
    function protectFinancialPrivacy(address borrower) public onlyAdmin {
        // In real implementation, implement privacy measures
        // For example: delete borrowerLoans[borrower];
    }
    
    /// @notice Calculate debt sustainability
    function calculateDebtSustainability(uint256 loanId) public view returns (euint32) {
        euint32 dti = calculateDebtToIncome(loanId);
        return FHE.sub(FHE.asEuint32(100), dti);
    }
    
    /// @notice Estimate inflation impact
    function estimateInflationImpact(uint256 loanId) public view returns (euint32) {
        AmortizationSchedule storage schedule = amortizationSchedules[loanId];
        require(schedule.isCalculated, "Schedule not calculated");
        
        // Inflation reduces real interest cost
        return FHE.div(schedule.encryptedTotalInterest, FHE.asEuint32(2));
    }
}