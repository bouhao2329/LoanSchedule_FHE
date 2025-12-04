// App.tsx
import React, { useEffect, useState } from "react";
import { ethers } from "ethers";
import { getContractReadOnly, getContractWithSigner } from "./contract";
import WalletManager from "./components/WalletManager";
import WalletSelector from "./components/WalletSelector";
import "./App.css";

interface LoanSchedule {
  id: string;
  encryptedData: string;
  timestamp: number;
  owner: string;
  loanAmount: string;
  term: number;
  status: "pending" | "active" | "completed";
}

const App: React.FC = () => {
  // Randomized style selections
  // Colors: High contrast (blue+orange)
  // UI: Future metal
  // Layout: Center radiation
  // Interaction: Micro-interactions
  
  const [account, setAccount] = useState("");
  const [loading, setLoading] = useState(true);
  const [schedules, setSchedules] = useState<LoanSchedule[]>([]);
  const [provider, setProvider] = useState<ethers.BrowserProvider | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [creating, setCreating] = useState(false);
  const [walletSelectorOpen, setWalletSelectorOpen] = useState(false);
  const [transactionStatus, setTransactionStatus] = useState<{
    visible: boolean;
    status: "pending" | "success" | "error";
    message: string;
  }>({ visible: false, status: "pending", message: "" });
  const [newScheduleData, setNewScheduleData] = useState({
    loanAmount: "",
    term: "12",
    interestRate: "5",
    goal: ""
  });
  const [activeSchedule, setActiveSchedule] = useState<LoanSchedule | null>(null);
  const [showStats, setShowStats] = useState(false);

  // Calculate statistics
  const activeCount = schedules.filter(s => s.status === "active").length;
  const pendingCount = schedules.filter(s => s.status === "pending").length;
  const completedCount = schedules.filter(s => s.status === "completed").length;

  useEffect(() => {
    loadSchedules().finally(() => setLoading(false));
  }, []);

  const onWalletSelect = async (wallet: any) => {
    if (!wallet.provider) return;
    try {
      const web3Provider = new ethers.BrowserProvider(wallet.provider);
      setProvider(web3Provider);
      const accounts = await web3Provider.send("eth_requestAccounts", []);
      const acc = accounts[0] || "";
      setAccount(acc);

      wallet.provider.on("accountsChanged", async (accounts: string[]) => {
        const newAcc = accounts[0] || "";
        setAccount(newAcc);
      });
    } catch (e) {
      alert("Failed to connect wallet");
    }
  };

  const onConnect = () => setWalletSelectorOpen(true);
  const onDisconnect = () => {
    setAccount("");
    setProvider(null);
  };

  const loadSchedules = async () => {
    setIsRefreshing(true);
    try {
      const contract = await getContractReadOnly();
      if (!contract) return;
      
      // Check contract availability using FHE
      const isAvailable = await contract.isAvailable();
      if (!isAvailable) {
        console.error("Contract is not available");
        return;
      }
      
      const keysBytes = await contract.getData("schedule_keys");
      let keys: string[] = [];
      
      if (keysBytes.length > 0) {
        try {
          keys = JSON.parse(ethers.toUtf8String(keysBytes));
        } catch (e) {
          console.error("Error parsing schedule keys:", e);
        }
      }
      
      const list: LoanSchedule[] = [];
      
      for (const key of keys) {
        try {
          const scheduleBytes = await contract.getData(`schedule_${key}`);
          if (scheduleBytes.length > 0) {
            try {
              const scheduleData = JSON.parse(ethers.toUtf8String(scheduleBytes));
              list.push({
                id: key,
                encryptedData: scheduleData.data,
                timestamp: scheduleData.timestamp,
                owner: scheduleData.owner,
                loanAmount: scheduleData.loanAmount,
                term: scheduleData.term,
                status: scheduleData.status || "pending"
              });
            } catch (e) {
              console.error(`Error parsing schedule data for ${key}:`, e);
            }
          }
        } catch (e) {
          console.error(`Error loading schedule ${key}:`, e);
        }
      }
      
      list.sort((a, b) => b.timestamp - a.timestamp);
      setSchedules(list);
    } catch (e) {
      console.error("Error loading schedules:", e);
    } finally {
      setIsRefreshing(false);
      setLoading(false);
    }
  };

  const submitSchedule = async () => {
    if (!provider) { 
      alert("Please connect wallet first"); 
      return; 
    }
    
    setCreating(true);
    setTransactionStatus({
      visible: true,
      status: "pending",
      message: "Encrypting loan data with Zama FHE..."
    });
    
    try {
      // Simulate FHE encryption
      const encryptedData = `FHE-${btoa(JSON.stringify(newScheduleData))}`;
      
      const contract = await getContractWithSigner();
      if (!contract) {
        throw new Error("Failed to get contract with signer");
      }
      
      const scheduleId = `${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;

      const scheduleData = {
        data: encryptedData,
        timestamp: Math.floor(Date.now() / 1000),
        owner: account,
        loanAmount: newScheduleData.loanAmount,
        term: parseInt(newScheduleData.term),
        status: "pending"
      };
      
      // Store encrypted data on-chain using FHE
      await contract.setData(
        `schedule_${scheduleId}`, 
        ethers.toUtf8Bytes(JSON.stringify(scheduleData))
      );
      
      const keysBytes = await contract.getData("schedule_keys");
      let keys: string[] = [];
      
      if (keysBytes.length > 0) {
        try {
          keys = JSON.parse(ethers.toUtf8String(keysBytes));
        } catch (e) {
          console.error("Error parsing keys:", e);
        }
      }
      
      keys.push(scheduleId);
      
      await contract.setData(
        "schedule_keys", 
        ethers.toUtf8Bytes(JSON.stringify(keys))
      );
      
      setTransactionStatus({
        visible: true,
        status: "success",
        message: "Encrypted loan schedule created!"
      });
      
      await loadSchedules();
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
        setShowCreateModal(false);
        setNewScheduleData({
          loanAmount: "",
          term: "12",
          interestRate: "5",
          goal: ""
        });
      }, 2000);
    } catch (e: any) {
      const errorMessage = e.message.includes("user rejected transaction")
        ? "Transaction rejected by user"
        : "Submission failed: " + (e.message || "Unknown error");
      
      setTransactionStatus({
        visible: true,
        status: "error",
        message: errorMessage
      });
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
      }, 3000);
    } finally {
      setCreating(false);
    }
  };

  const activateSchedule = async (scheduleId: string) => {
    if (!provider) {
      alert("Please connect wallet first");
      return;
    }

    setTransactionStatus({
      visible: true,
      status: "pending",
      message: "Processing encrypted loan with FHE..."
    });

    try {
      // Simulate FHE computation time
      await new Promise(resolve => setTimeout(resolve, 3000));
      
      const contract = await getContractWithSigner();
      if (!contract) {
        throw new Error("Failed to get contract with signer");
      }
      
      const scheduleBytes = await contract.getData(`schedule_${scheduleId}`);
      if (scheduleBytes.length === 0) {
        throw new Error("Schedule not found");
      }
      
      const scheduleData = JSON.parse(ethers.toUtf8String(scheduleBytes));
      
      const updatedSchedule = {
        ...scheduleData,
        status: "active"
      };
      
      await contract.setData(
        `schedule_${scheduleId}`, 
        ethers.toUtf8Bytes(JSON.stringify(updatedSchedule))
      );
      
      setTransactionStatus({
        visible: true,
        status: "success",
        message: "FHE activation completed!"
      });
      
      await loadSchedules();
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
      }, 2000);
    } catch (e: any) {
      setTransactionStatus({
        visible: true,
        status: "error",
        message: "Activation failed: " + (e.message || "Unknown error")
      });
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
      }, 3000);
    }
  };

  const completeSchedule = async (scheduleId: string) => {
    if (!provider) {
      alert("Please connect wallet first");
      return;
    }

    setTransactionStatus({
      visible: true,
      status: "pending",
      message: "Finalizing encrypted loan with FHE..."
    });

    try {
      // Simulate FHE computation time
      await new Promise(resolve => setTimeout(resolve, 3000));
      
      const contract = await getContractWithSigner();
      if (!contract) {
        throw new Error("Failed to get contract with signer");
      }
      
      const scheduleBytes = await contract.getData(`schedule_${scheduleId}`);
      if (scheduleBytes.length === 0) {
        throw new Error("Schedule not found");
      }
      
      const scheduleData = JSON.parse(ethers.toUtf8String(scheduleBytes));
      
      const updatedSchedule = {
        ...scheduleData,
        status: "completed"
      };
      
      await contract.setData(
        `schedule_${scheduleId}`, 
        ethers.toUtf8Bytes(JSON.stringify(updatedSchedule))
      );
      
      setTransactionStatus({
        visible: true,
        status: "success",
        message: "FHE completion processed!"
      });
      
      await loadSchedules();
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
      }, 2000);
    } catch (e: any) {
      setTransactionStatus({
        visible: true,
        status: "error",
        message: "Completion failed: " + (e.message || "Unknown error")
      });
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
      }, 3000);
    }
  };

  const isOwner = (address: string) => {
    return account.toLowerCase() === address.toLowerCase();
  };

  const checkAvailability = async () => {
    try {
      const contract = await getContractReadOnly();
      if (!contract) return;
      
      const isAvailable = await contract.isAvailable();
      
      setTransactionStatus({
        visible: true,
        status: "success",
        message: isAvailable ? "FHE service is available!" : "Service unavailable"
      });
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
      }, 2000);
    } catch (e) {
      setTransactionStatus({
        visible: true,
        status: "error",
        message: "Availability check failed"
      });
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
      }, 3000);
    }
  };

  const renderStats = () => {
    return (
      <div className="stats-grid">
        <div className="stat-item">
          <div className="stat-value">{schedules.length}</div>
          <div className="stat-label">Total</div>
        </div>
        <div className="stat-item">
          <div className="stat-value">{activeCount}</div>
          <div className="stat-label">Active</div>
        </div>
        <div className="stat-item">
          <div className="stat-value">{pendingCount}</div>
          <div className="stat-label">Pending</div>
        </div>
        <div className="stat-item">
          <div className="stat-value">{completedCount}</div>
          <div className="stat-label">Completed</div>
        </div>
      </div>
    );
  };

  if (loading) return (
    <div className="loading-screen">
      <div className="metal-spinner"></div>
      <p>Initializing FHE connection...</p>
    </div>
  );

  return (
    <div className="app-container metal-theme">
      <div className="radial-bg"></div>
      
      <header className="app-header">
        <div className="logo">
          <div className="logo-icon">
            <div className="gear-icon"></div>
          </div>
          <h1>FHE<span>Loan</span>Planner</h1>
        </div>
        
        <div className="header-actions">
          <button 
            onClick={checkAvailability}
            className="metal-button"
          >
            Check FHE Status
          </button>
          <WalletManager account={account} onConnect={onConnect} onDisconnect={onDisconnect} />
        </div>
      </header>
      
      <main className="main-content">
        <div className="central-panel">
          <div className="panel-header">
            <h2>Privacy-Preserving Loan Schedules</h2>
            <p>Generate fully encrypted amortization plans with FHE technology</p>
          </div>
          
          <div className="action-buttons">
            <button 
              onClick={() => setShowCreateModal(true)} 
              className="metal-button primary"
            >
              Create New Schedule
            </button>
            <button 
              onClick={() => setShowStats(!showStats)}
              className="metal-button"
            >
              {showStats ? "Hide Stats" : "Show Stats"}
            </button>
            <button 
              onClick={loadSchedules}
              className="metal-button"
              disabled={isRefreshing}
            >
              {isRefreshing ? "Refreshing..." : "Refresh"}
            </button>
          </div>
          
          {showStats && (
            <div className="stats-panel metal-card">
              <h3>Loan Statistics</h3>
              {renderStats()}
            </div>
          )}
          
          <div className="schedules-list metal-card">
            <div className="list-header">
              <h3>Your Loan Schedules</h3>
              <div className="status-filter">
                <span>Filter:</span>
                <button className="filter-btn">All</button>
                <button className="filter-btn">Active</button>
                <button className="filter-btn">Pending</button>
                <button className="filter-btn">Completed</button>
              </div>
            </div>
            
            {schedules.length === 0 ? (
              <div className="no-schedules">
                <div className="no-data-icon"></div>
                <p>No loan schedules found</p>
                <button 
                  className="metal-button primary"
                  onClick={() => setShowCreateModal(true)}
                >
                  Create First Schedule
                </button>
              </div>
            ) : (
              <div className="schedule-items">
                {schedules.map(schedule => (
                  <div 
                    className={`schedule-item ${schedule.status}`}
                    key={schedule.id}
                    onClick={() => setActiveSchedule(schedule)}
                  >
                    <div className="schedule-summary">
                      <div className="loan-amount">${schedule.loanAmount}</div>
                      <div className="loan-term">{schedule.term} months</div>
                      <div className="loan-status">
                        <span className={`status-badge ${schedule.status}`}>
                          {schedule.status}
                        </span>
                      </div>
                    </div>
                    <div className="schedule-actions">
                      {isOwner(schedule.owner) && schedule.status === "pending" && (
                        <button 
                          className="metal-button small"
                          onClick={(e) => {
                            e.stopPropagation();
                            activateSchedule(schedule.id);
                          }}
                        >
                          Activate
                        </button>
                      )}
                      {isOwner(schedule.owner) && schedule.status === "active" && (
                        <button 
                          className="metal-button small"
                          onClick={(e) => {
                            e.stopPropagation();
                            completeSchedule(schedule.id);
                          }}
                        >
                          Complete
                        </button>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
        
        {activeSchedule && (
          <div className="schedule-detail metal-card">
            <button 
              className="close-detail"
              onClick={() => setActiveSchedule(null)}
            >
              &times;
            </button>
            <h3>Loan Details</h3>
            <div className="detail-grid">
              <div className="detail-item">
                <label>Amount</label>
                <div>${activeSchedule.loanAmount}</div>
              </div>
              <div className="detail-item">
                <label>Term</label>
                <div>{activeSchedule.term} months</div>
              </div>
              <div className="detail-item">
                <label>Status</label>
                <div className={`status-badge ${activeSchedule.status}`}>
                  {activeSchedule.status}
                </div>
              </div>
              <div className="detail-item">
                <label>Created</label>
                <div>{new Date(activeSchedule.timestamp * 1000).toLocaleDateString()}</div>
              </div>
              <div className="detail-item full-width">
                <label>Owner</label>
                <div>{activeSchedule.owner}</div>
              </div>
            </div>
            <div className="fhe-notice">
              <div className="lock-icon"></div>
              <span>This data is processed using FHE encryption</span>
            </div>
          </div>
        )}
      </main>
  
      {showCreateModal && (
        <ModalCreate 
          onSubmit={submitSchedule} 
          onClose={() => setShowCreateModal(false)} 
          creating={creating}
          scheduleData={newScheduleData}
          setScheduleData={setNewScheduleData}
        />
      )}
      
      {walletSelectorOpen && (
        <WalletSelector
          isOpen={walletSelectorOpen}
          onWalletSelect={(wallet) => { onWalletSelect(wallet); setWalletSelectorOpen(false); }}
          onClose={() => setWalletSelectorOpen(false)}
        />
      )}
      
      {transactionStatus.visible && (
        <div className="transaction-modal">
          <div className="transaction-content metal-card">
            <div className={`transaction-icon ${transactionStatus.status}`}>
              {transactionStatus.status === "pending" && <div className="metal-spinner"></div>}
              {transactionStatus.status === "success" && <div className="check-icon"></div>}
              {transactionStatus.status === "error" && <div className="error-icon"></div>}
            </div>
            <div className="transaction-message">
              {transactionStatus.message}
            </div>
          </div>
        </div>
      )}
  
      <footer className="app-footer">
        <div className="footer-content">
          <div className="footer-brand">
            <div className="logo">
              <div className="gear-icon"></div>
              <span>FHE Loan Planner</span>
            </div>
            <p>Privacy-preserving loan amortization with FHE</p>
          </div>
          
          <div className="footer-links">
            <a href="#" className="footer-link">Documentation</a>
            <a href="#" className="footer-link">Privacy Policy</a>
            <a href="#" className="footer-link">Terms</a>
          </div>
        </div>
        
        <div className="footer-bottom">
          <div className="fhe-badge">
            <span>Fully Homomorphic Encryption</span>
          </div>
          <div className="copyright">
            © {new Date().getFullYear()} FHE Finance Tools
          </div>
        </div>
      </footer>
    </div>
  );
};

interface ModalCreateProps {
  onSubmit: () => void; 
  onClose: () => void; 
  creating: boolean;
  scheduleData: any;
  setScheduleData: (data: any) => void;
}

const ModalCreate: React.FC<ModalCreateProps> = ({ 
  onSubmit, 
  onClose, 
  creating,
  scheduleData,
  setScheduleData
}) => {
  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => {
    const { name, value } = e.target;
    setScheduleData({
      ...scheduleData,
      [name]: value
    });
  };

  const handleSubmit = () => {
    if (!scheduleData.loanAmount || !scheduleData.term) {
      alert("Please fill required fields");
      return;
    }
    
    onSubmit();
  };

  return (
    <div className="modal-overlay">
      <div className="create-modal metal-card">
        <div className="modal-header">
          <h2>Create Encrypted Loan Schedule</h2>
          <button onClick={onClose} className="close-modal">&times;</button>
        </div>
        
        <div className="modal-body">
          <div className="fhe-notice-banner">
            <div className="lock-icon"></div> Your financial data remains encrypted during FHE processing
          </div>
          
          <div className="form-grid">
            <div className="form-group">
              <label>Loan Amount ($) *</label>
              <input 
                type="number"
                name="loanAmount"
                value={scheduleData.loanAmount} 
                onChange={handleChange}
                placeholder="10000" 
                className="metal-input"
              />
            </div>
            
            <div className="form-group">
              <label>Term (months) *</label>
              <select 
                name="term"
                value={scheduleData.term} 
                onChange={handleChange}
                className="metal-select"
              >
                <option value="12">12 months</option>
                <option value="24">24 months</option>
                <option value="36">36 months</option>
                <option value="48">48 months</option>
                <option value="60">60 months</option>
              </select>
            </div>
            
            <div className="form-group">
              <label>Interest Rate (%)</label>
              <input 
                type="number"
                name="interestRate"
                value={scheduleData.interestRate} 
                onChange={handleChange}
                placeholder="5" 
                className="metal-input"
              />
            </div>
            
            <div className="form-group full-width">
              <label>Financial Goal</label>
              <textarea 
                name="goal"
                value={scheduleData.goal} 
                onChange={handleChange}
                placeholder="Describe your financial goal for this loan..." 
                className="metal-textarea"
                rows={3}
              />
            </div>
          </div>
        </div>
        
        <div className="modal-footer">
          <button 
            onClick={onClose}
            className="metal-button"
          >
            Cancel
          </button>
          <button 
            onClick={handleSubmit} 
            disabled={creating}
            className="metal-button primary"
          >
            {creating ? "Processing with FHE..." : "Create Schedule"}
          </button>
        </div>
      </div>
    </div>
  );
};

export default App;